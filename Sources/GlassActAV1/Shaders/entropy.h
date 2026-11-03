// Glass Act: av1gpu's GPU entropy coder (av1core/src/gpu_entropy.cu, BSD-2, Sources/AV1Core/LICENSE),
// for Metal and one picture. Its symbolization is parallel because every context of the AV1 intra
// syntax is a function of the DecisionRecord only, never of CDF values:
//   e_blocks / e_sbs / e_tiles   per block / SB / tile: tile and SB block ranges, decode-order
//                                checks, the delta-q CurrentQIndex chain (SIMD-group scan)
//   e_maps    per block:    4x4 mode-info maps (MiSize, YMode, Skip, TxSize)
//   e_txctx   per tx block: eob, culLevel, dcCategory -> the per-plane 4x4 context maps
//   e_txsym   per tx block: coefficient syntax          } a count pass, an exclusive scan, then an
//   e_sbsym   per 64x64 SB: partition + mode info syntax } emit pass: streams in bitstream order
//   e_entropy per tile:     windows of 32 symbols; CDF adaptation lane-parallel (serial only
//                           between symbols of one CDF), then lane 0 range-codes the window's
//                           precomputed words
// The output is byte-identical to av1core's CPU writer, which shares these headers.
//
// Deviations from the CUDA:
// - One picture: no frame tables, binary searches or per-frame bases.
// - The partition walk is recursive in CUDA; Metal has no recursion, so it runs over an explicit
//   stack (and codes each node's blocks in one loop, so ent_block is inlined once).
// - e_entropy is one SIMD-group per tile: CUDA's second warp, which range-codes window w while the
//   first adapts window w + 1, spins on shared counters, and Metal doesn't promise SIMD-groups
//   forward progress against each other. Here the two phases alternate.
// - __match_any_sync is a ballot loop over the window's distinct CDFs.
// - The CDF defaults (4 coefficient q contexts) are made once per encoder, not per batch.
#pragma once
#include "cuda_compat.h"
#include "av1g/hd.h"
#include "av1g/enums_gen.h"
#include "av1g/spec_tables.h"
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/cdfctx.h"
#include "av1g/entenc.h"
#include "av1g/symstream.h"
#include "av1enc/ent.h"

#ifndef CID
#define CID(expr) ((uint32_t)(__builtin_offsetof(av1g_cdfs, expr) / 2))
#endif

static inline void ent_fail(constant GaEntBufs &B, int bits) {
    atomic_fetch_or_explicit((device atomic_int *)&B.status->error, bits, memory_order_relaxed);
}

static inline uint ent_ballot(bool b) { return (uint)static_cast<simd_vote::vote_t>(simd_ballot(b)); }

struct EntOut {
    device uint32_t *p;
    uint32_t n;
    void put(uint32_t w) { if (p) p[n] = w; n++; }
    void sym(uint32_t cid, int s, int N) { put(av1g_sym_pack(AV1G_SYM_ADAPT, cid, (uint32_t)s, (uint32_t)N)); }
    void bit(int b) { put(av1g_sym_pack(AV1G_SYM_BOOL, 0, (uint32_t)b, 2)); }
};

// ---------------------------------------------------------------------------
// prep

// decode-order SB index of a block, and its tile
static inline uint32_t ent_sb_key(constant GaEntFrame &F, device const GaEntTile *T, av1g_block k, thread uint32_t &tile) {
    const int sbR = k.mi_row >> 4, sbC = k.mi_col >> 4;
    const int tr = min(sbR / F.tileHsb, F.tileRows - 1), tc = min(sbC / F.tileWsb, F.tileCols - 1);
    tile = (uint32_t)(tr * F.tileCols + tc);
    const GaEntTile tl = T[tile];
    return tl.sbBase + (uint32_t)((sbR - tl.sbRow0) * tl.sbCols + (sbC - tl.sbCol0));
}

kernel void e_blocks(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                     uint b [[thread_position_in_grid]]) {
    const uint32_t nB = F.nBlocks, nT = F.nTxb;
    if (b >= nB) return;
    const av1g_block k = B.blocks[b];
    if (k.mi_row >= F.MiRows || k.mi_col >= F.MiCols) {
        ent_fail(B, GA_ENT_ERR_ORDER);
        B.blockTile[b] = 0;
        B.blockTxbG[b] = 0;
        return;
    }
    uint32_t tile;
    const uint32_t key = ent_sb_key(F, B.tiles, k, tile);
    B.blockTile[b] = tile;
    const uint32_t t0 = B.blockTxb[b], t1 = b + 1 < nB ? B.blockTxb[b + 1] : nT;
    bool bad = t1 < t0 || t1 > nT || (b == 0 && t0 != 0);
    B.blockTxbG[b] = min(t0, nT);
    if (!bad)
        for (uint32_t t = t0; t < t1; t++) B.txbBlock[t] = b;
    if (b == 0) {
        if (key != 0) bad = true;
        else B.sbFirst[0] = 0;
    } else {
        uint32_t pt;
        const uint32_t pkey = ent_sb_key(F, B.tiles, B.blocks[b - 1], pt);
        if (key == pkey + 1) B.sbFirst[key] = b;
        else if (key != pkey) bad = true;
    }
    if (b + 1 == nB && key + 1 != F.nSb) bad = true;
    if (bad) ent_fail(B, GA_ENT_ERR_ORDER);
    if (b + 1 == nB) B.blockTxbG[nB] = nT;
}

kernel void e_sbs(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                  uint s [[thread_position_in_grid]]) {
    if (s >= F.nSb) return;
    uint32_t lo = 0, hi = F.nTiles;  // the tile of SB s
    while (hi - lo > 1) {
        const uint32_t mid = (lo + hi) >> 1;
        if (B.tiles[mid].sbBase <= s) lo = mid; else hi = mid;
    }
    const GaEntTile tl = B.tiles[lo];
    const uint32_t local = s - tl.sbBase;
    GaEntSb o;
    o.tile = lo;
    o.r = (tl.sbRow0 + (int)(local / (uint32_t)tl.sbCols)) * 16;
    o.c = (tl.sbCol0 + (int)(local % (uint32_t)tl.sbCols)) * 16;
    o.firstBlock = B.sbFirst[s];
    o.endBlock = s + 1 < F.nSb ? B.sbFirst[s + 1] : F.nBlocks;
    if (o.firstBlock == 0xFFFFFFFFu || o.endBlock == 0xFFFFFFFFu || o.firstBlock >= o.endBlock || o.endBlock > F.nBlocks) {
        ent_fail(B, GA_ENT_ERR_ORDER);
        o.firstBlock = o.endBlock = 0;
    }
    o.qBefore = F.qidx;
    B.sbs[s] = o;
}

// one SIMD-group per tile: its block range, and CurrentQIndex before every SB (reset to
// base_q_idx at the tile start, updated by the first block of each SB unless it is a skipped 64x64)
kernel void e_tiles(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                    uint t [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]]) {
    const GaEntTile tl = B.tiles[t];
    if (lane == 0) {
        B.tiles[t].firstBlock = B.sbs[tl.sbBase].firstBlock;
        B.tiles[t].endBlock = B.sbs[tl.sbBase + tl.nSb - 1].endBlock;
    }
    if (!F.dq) return;
    int carry = F.qidx;
    for (uint32_t base = 0; base < tl.nSb; base += 32) {
        const uint32_t i = base + lane;
        bool coded = false;
        int val = 0;
        if (i < tl.nSb) {
            const GaEntSb s = B.sbs[tl.sbBase + i];
            if (s.firstBlock < s.endBlock) {
                const av1g_block fb = B.blocks[s.firstBlock];
                coded = !(fb.bsize == AV1G_BLOCK_64X64 && fb.skip);
                val = fb.sb_qindex;
            }
        }
        const uint mask = ent_ballot(coded);
        const uint lower = mask & ((1u << lane) - 1u);
        const int v = simd_shuffle(val, (ushort)(lower ? 31 - clz(lower) : 0));
        if (i < tl.nSb) B.sbs[tl.sbBase + i].qBefore = lower ? v : carry;
        if (mask) carry = simd_shuffle(val, (ushort)(31 - clz(mask)));
    }
}

// ---------------------------------------------------------------------------
// maps

kernel void e_maps(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                   uint b [[thread_position_in_grid]]) {
    if (b >= F.nBlocks) return;
    const av1g_block k = B.blocks[b];
    const int bw4 = av1g_bw4(k.bsize), bh4 = av1g_bh4(k.bsize);
    const int rEnd = min(k.mi_row + bh4, F.MiRows), cEnd = min(k.mi_col + bw4, F.MiCols);
    const uint8_t tx = (uint8_t)av1g_luma_tx_size(k.bsize, k.tx_depth);
    for (int y = k.mi_row; y < rEnd; y++)
        for (int x = k.mi_col; x < cEnd; x++) {
            const uint32_t i = (uint32_t)(y * F.MiCols + x);
            B.mMiSize[i] = k.bsize;
            B.mYMode[i] = k.y_mode;
            B.mSkip[i] = k.skip;
            B.mTx[i] = tx;
        }
}

kernel void e_txctx(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                    uint t [[thread_position_in_grid]]) {
    if (t >= F.nTxb) return;
    const av1g_block k = B.blocks[B.txbBlock[t]];
    const av1g_txb x = B.txb[t];
    const int plane = x.plane, txSz = x.tx_size;
    int type = plane ? av1g_chroma_tx_type(txSz, k.uv_mode, F.reduced) : x.tx_type;
    int eob = 0, cul = 0, dc = 0;
    if (!k.skip) {
        device const int16_t *q = B.coeffs + x.coeff_off;
        AV1G_CONST const uint16_t *scan = av1g_get_scan(txSz, type);
        const int n = av1g_tx_coeffs(txSz);
        for (int c = n - 1; c >= 0; c--)
            if (q[scan[c]]) { eob = c + 1; break; }
        for (int c = 0; c < eob; c++) {
            const int v = q[scan[c]];
            cul += v < 0 ? -v : v;
        }
        if (cul > 63) cul = 63;
        dc = q[0] < 0 ? 1 : q[0] > 0 ? 2 : 0;
    }
    if (!eob && plane == 0) type = AV1G_DCT_DCT;
    B.txbEob[t] = (uint16_t)eob;
    B.txbType[t] = (uint8_t)type;
    const int w4 = av1g_tx_w(txSz) >> 2, h4 = av1g_tx_h(txSz) >> 2;
    const int stride = F.ctxStride[plane], rows = F.ctxRows[plane];
    for (int i = 0; i < h4 && x.y4 + i < rows; i++)
        for (int j = 0; j < w4 && x.x4 + j < stride; j++) {
            const uint32_t o = F.ctxBase[plane] + (uint32_t)((x.y4 + i) * stride + x.x4 + j);
            B.ctxLvl[o] = (uint8_t)cul;
            B.ctxDc[o] = (uint8_t)dc;
        }
}

// ---------------------------------------------------------------------------
// coefficient syntax of one tx block (mirror of Encoder::code_coeffs, write mode)

kernel void e_txsym(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                    constant uint32_t &emit [[buffer(2)]], uint t [[thread_position_in_grid]]) {
    if (t >= F.nTxb) return;
    const uint32_t nItems = F.nBlocks + F.nTxb;
    if (emit && B.off[nItems] > F.symCap) return;  // too small a symbol buffer (reported later)
    const uint32_t b = B.txbBlock[t];
    const uint32_t item = t + b + 1;
    const av1g_block k = B.blocks[b];
    EntOut o{emit ? B.syms + B.off[item] : nullptr, 0};
    if (k.skip) {
        if (!emit) B.count[item] = 0;
        return;
    }
    const GaEntTile T = B.tiles[B.blockTile[b]];
    const av1g_txb x = B.txb[t];
    const int plane = x.plane, txSz = x.tx_size, sub = plane ? 1 : 0, ptype = plane > 0;
    const int x4 = x.x4, y4 = x.y4;
    const int eob = B.txbEob[t], txType = B.txbType[t];
    device const int16_t *q = B.coeffs + x.coeff_off;
    const int txSzCtx = (AV1G_T(Tx_Size_Sqr)[txSz] + AV1G_T(Tx_Size_Sqr_Up)[txSz] + 1) >> 1;
    const int w = AV1G_T(Tx_Width)[txSz], h = AV1G_T(Tx_Height)[txSz], w4 = w >> 2, h4 = h >> 2;
    const int maxX4 = F.MiCols >> sub, maxY4 = F.MiRows >> sub;
    const int stride = F.ctxStride[plane];
    device const uint8_t *L = B.ctxLvl + F.ctxBase[plane], *Dc = B.ctxDc + F.ctxBase[plane];
    const bool hasAbove = y4 > (T.miRowStart >> sub), hasLeft = x4 > (T.miColStart >> sub);
    auto aLvl = [&](int k_) -> int { return hasAbove ? L[(y4 - 1) * stride + x4 + k_] : 0; };
    auto aDc = [&](int k_) -> int { return hasAbove ? Dc[(y4 - 1) * stride + x4 + k_] : 0; };
    auto lLvl = [&](int k_) -> int { return hasLeft ? L[(y4 + k_) * stride + x4 - 1] : 0; };
    auto lDc = [&](int k_) -> int { return hasLeft ? Dc[(y4 + k_) * stride + x4 - 1] : 0; };
    int ctx;
    {
        const int bsz = plane ? av1g_uv_bsize(k.bsize) : k.bsize;
        const int bw = 4 * av1g_bw4(bsz), bh = 4 * av1g_bh4(bsz);
        if (plane == 0) {
            int top = 0, left = 0;
            for (int i = 0; i < w4; i++) if (x4 + i < maxX4) top = max(top, aLvl(i));
            for (int i = 0; i < h4; i++) if (y4 + i < maxY4) left = max(left, lLvl(i));
            const int mx = max(top, left), mn = min(top, left);
            if (bw == w && bh == h) ctx = 0;
            else if (top == 0 && left == 0) ctx = 1;
            else if (top == 0 || left == 0) ctx = 2 + (mx > 3);
            else if (mx <= 3) ctx = 4;
            else if (mn <= 3) ctx = 5;
            else ctx = 6;
        } else {
            int above = 0, left = 0;
            for (int i = 0; i < w4; i++) if (x4 + i < maxX4) above |= aLvl(i) | aDc(i);
            for (int i = 0; i < h4; i++) if (y4 + i < maxY4) left |= lLvl(i) | lDc(i);
            ctx = (above != 0) + (left != 0) + 7;
            if (bw * bh > w * h) ctx += 3;
        }
    }
    o.sym(CID(txb_skip[txSzCtx][ctx]), eob == 0, 2);
    if (eob > 0) {
        if (plane == 0) {
            const int set = av1g_get_tx_set_intra(txSz, F.reduced);
            if (set > 0) {
                const int sqr = AV1G_T(Tx_Size_Sqr)[txSz];
                const int intraDir = k.filter_intra ? AV1G_T(Filter_Intra_Mode_To_Intra_Dir)[k.filter_intra - 1] : k.y_mode;
                int idx = 0;
                if (set == AV1G_TX_SET_INTRA_1) {
                    for (int i = 0; i < 7; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set1)[i] == txType) idx = i;
                    o.sym(CID(intra_tx_set1[sqr][intraDir]), idx, 7);
                } else {
                    for (int i = 0; i < 5; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set2)[i] == txType) idx = i;
                    o.sym(CID(intra_tx_set2[sqr][intraDir]), idx, 5);
                }
            }
        }
        AV1G_CONST const uint16_t *scan = av1g_get_scan(txSz, txType);
        const int txClass = av1g_tx_class(txType);
        const int eobMultisize = min((int)AV1G_T(Tx_Width_Log2)[txSz], 5) + min((int)AV1G_T(Tx_Height_Log2)[txSz], 5) - 4;
        int eobPt;
        if (eob <= 2) eobPt = eob;
        else { eobPt = 2; int v = eob - 1; while (v > 1) { v >>= 1; eobPt++; } }
        {
            const int ectx = txClass == AV1G_TX_CLASS_2D ? 0 : 1;
            uint32_t c;
            switch (eobMultisize) {
            case 0: c = CID(eob_pt_16[ptype][ectx]); break;
            case 1: c = CID(eob_pt_32[ptype][ectx]); break;
            case 2: c = CID(eob_pt_64[ptype][ectx]); break;
            case 3: c = CID(eob_pt_128[ptype][ectx]); break;
            case 4: c = CID(eob_pt_256[ptype][ectx]); break;
            case 5: c = CID(eob_pt_512[ptype]); break;
            default: c = CID(eob_pt_1024[ptype]); break;
            }
            o.sym(c, eobPt - 1, eobMultisize + 5);
        }
        if (eobPt >= 3) {
            const int rem = eob - ((1 << (eobPt - 2)) + 1);
            o.sym(CID(eob_extra[txSzCtx][ptype][eobPt - 3]), (rem >> (eobPt - 3)) & 1, 2);
            for (int i = 1; i < eobPt - 2; i++) o.bit((rem >> (eobPt - 3 - i)) & 1);
        }
        const int adj = AV1G_T(Adjusted_Tx_Size)[txSz];
        const int bwl = AV1G_T(Tx_Width_Log2)[adj];
        const int width = 1 << bwl, height = AV1G_T(Tx_Height)[adj];
        uint8_t lev[1024];
        for (int i = 0; i < width * height; i++) lev[i] = 0;
        for (int c = eob - 1; c >= 0; c--) {
            const int pos = scan[c];
            const int v = q[pos] < 0 ? -q[pos] : q[pos];
            const int level = v < 15 ? v : 15;
            const int row = pos >> bwl, col = pos - (row << bwl);
            if (c == eob - 1) {
                const int bctx = c == 0 ? 0 : c <= (height << bwl) / 8 ? 1 : c <= (height << bwl) / 4 ? 2 : 3;
                o.sym(CID(coeff_base_eob[txSzCtx][ptype][bctx]), min(level, 3) - 1, 3);
            } else {
                int mag = 0;
                for (int idx = 0; idx < AV1G_SIG_REF_DIFF_OFFSET_NUM; idx++) {
                    const int rr = row + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][0];
                    const int cc = col + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][1];
                    if (rr >= 0 && cc >= 0 && rr < height && cc < width) mag += min((int)lev[(rr << bwl) + cc], 3);
                }
                int bctx = min((mag + 1) >> 1, 4);
                if (txClass == AV1G_TX_CLASS_2D) {
                    if (row == 0 && col == 0) bctx = 0;
                    else bctx += AV1G_T(Coeff_Base_Ctx_Offset)[txSz][min(row, 4)][min(col, 4)];
                } else {
                    const int id = txClass == AV1G_TX_CLASS_VERT ? row : col;
                    bctx += AV1G_T(Coeff_Base_Pos_Ctx_Offset)[min(id, 2)];
                }
                o.sym(CID(coeff_base[txSzCtx][ptype][bctx]), min(level, 3), 4);
            }
            if (level > AV1G_NUM_BASE_LEVELS) {
                int mag = 0;
                for (int idx = 0; idx < 3; idx++) {
                    const int rr = row + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][0];
                    const int cc = col + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][1];
                    if (rr >= 0 && cc >= 0 && rr < height && cc < width) mag += min((int)lev[rr * width + cc], 15);
                }
                mag = min((mag + 1) >> 1, 6);
                int brctx;
                if (pos == 0) brctx = mag;
                else if (txClass == AV1G_TX_CLASS_2D) brctx = (row < 2 && col < 2) ? mag + 7 : mag + 14;
                else if (txClass == AV1G_TX_CLASS_HORIZ) brctx = col == 0 ? mag + 7 : mag + 14;
                else brctx = row == 0 ? mag + 7 : mag + 14;
                const int brsz = min(txSzCtx, (int)AV1G_TX_32X32);
                int rem = level - 3;
                for (int idx = 0; idx < AV1G_COEFF_BASE_RANGE / (AV1G_BR_CDF_SIZE - 1); idx++) {
                    const int kk = min(rem, 3);
                    o.sym(CID(coeff_br[brsz][ptype][brctx]), kk, AV1G_BR_CDF_SIZE);
                    rem -= kk;
                    if (kk < 3) break;
                }
            }
            lev[pos] = (uint8_t)level;
        }
        for (int c = 0; c < eob; c++) {
            const int pos = scan[c];
            const int v = q[pos];
            if (!v) continue;
            const int sign = v < 0, a = sign ? -v : v;
            if (c == 0) {
                int dcSign = 0;
                for (int i = 0; i < w4; i++)
                    if (x4 + i < maxX4) { const int s = aDc(i); dcSign += s == 1 ? -1 : s == 2 ? 1 : 0; }
                for (int i = 0; i < h4; i++)
                    if (y4 + i < maxY4) { const int s = lDc(i); dcSign += s == 1 ? -1 : s == 2 ? 1 : 0; }
                o.sym(CID(dc_sign[ptype][dcSign < 0 ? 1 : dcSign > 0 ? 2 : 0]), sign, 2);
            } else {
                o.bit(sign);
            }
            if (a > AV1G_NUM_BASE_LEVELS + AV1G_COEFF_BASE_RANGE) {
                const uint32_t xg = (uint32_t)(a - (AV1G_NUM_BASE_LEVELS + AV1G_COEFF_BASE_RANGE));
                int len = 0;
                while ((xg >> len) > 1) len++;
                for (int i = 0; i < len; i++) o.bit(0);
                o.bit(1);
                for (int i = len - 1; i >= 0; i--) o.bit((xg >> i) & 1);
            }
        }
    }
    if (!emit) B.count[item] = o.n;
}

// ---------------------------------------------------------------------------
// superblock walk: partition + mode info (mirror of encode_partition / encode_block)

struct EntWalk {
    constant GaEntFrame *F;
    GaEntTile T;
    constant GaEntBufs *B;
    uint32_t cursor, end;
    bool emit;
    uint32_t pend[8];
    int npend;
    int curQ, firstInSb, cdefDone;
    bool inside(int r, int c) const {
        return c >= T.miColStart && c < T.miColEnd && r >= T.miRowStart && r < T.miRowEnd;
    }
    int map(device const uint8_t *m, int r, int c) const { return m[r * F->MiCols + c]; }
};

static int ent_derive(thread EntWalk &w, int r, int c, int bSize, int hasRows, int hasCols) {
    device const av1g_block *blocks = w.B->blocks;
    const av1g_block b = blocks[w.cursor];
    const int hf = av1g_bw4(bSize) >> 1;
    const int hz = AV1G_T(Partition_Subsize)[AV1G_PARTITION_HORZ][bSize];
    const int vt = AV1G_T(Partition_Subsize)[AV1G_PARTITION_VERT][bSize];
    const int sp = AV1G_T(Partition_Subsize)[AV1G_PARTITION_SPLIT][bSize];
    const int h4 = AV1G_T(Partition_Subsize)[AV1G_PARTITION_HORZ_4][bSize];
    const int v4 = AV1G_T(Partition_Subsize)[AV1G_PARTITION_VERT_4][bSize];
    auto at = [&](uint32_t k, int rr, int cc, int bs) {
        if (w.cursor + k >= w.end) return false;
        const av1g_block n = blocks[w.cursor + k];
        return n.mi_row == rr && n.mi_col == cc && n.bsize == bs;
    };
    const int bs = b.bsize;
    if (bs == bSize) return AV1G_PARTITION_NONE;
    if (bs == hz) return at(1, r + hf, c, sp) ? AV1G_PARTITION_HORZ_B : AV1G_PARTITION_HORZ;
    if (bs == vt) return at(1, r, c + hf, sp) ? AV1G_PARTITION_VERT_B : AV1G_PARTITION_VERT;
    if (bs == sp && bSize > AV1G_BLOCK_8X8 && hasRows && hasCols && at(1, r + hf, c, sp)) return AV1G_PARTITION_VERT_A;
    if (bs == sp && bSize > AV1G_BLOCK_8X8 && hasRows && hasCols && at(1, r, c + hf, sp) && at(2, r + hf, c, hz))
        return AV1G_PARTITION_HORZ_A;
    if (bSize > AV1G_BLOCK_8X8 && bs == h4) return AV1G_PARTITION_HORZ_4;
    if (bSize > AV1G_BLOCK_8X8 && bs == v4) return AV1G_PARTITION_VERT_4;
    return AV1G_PARTITION_SPLIT;
}

static void ent_block(thread EntWalk &w, int r, int c, int bsize) {
    constant GaEntBufs &B = *w.B;
    if (w.cursor >= w.end) { ent_fail(B, GA_ENT_ERR_ORDER); return; }
    const uint32_t bi = w.cursor++;
    const av1g_block k = B.blocks[bi];
    constant GaEntFrame &F = *w.F;
    const uint32_t item = bi + B.blockTxbG[bi];
    EntOut o{w.emit ? B.syms + B.off[item] : nullptr, 0};
    for (int i = 0; i < w.npend; i++) o.put(w.pend[i]);
    w.npend = 0;
    const int bw4 = av1g_bw4(bsize), bh4 = av1g_bh4(bsize);
    const int hasChroma = av1g_has_chroma(bsize, r, c, F.mono);
    const int aU = w.inside(r - 1, c), aL = w.inside(r, c - 1);
    o.sym(CID(skip[(aU ? w.map(B.mSkip, r - 1, c) : 0) + (aL ? w.map(B.mSkip, r, c - 1) : 0)]), k.skip, 2);
    if (F.cdefBits >= 0 && !k.skip && !w.cdefDone) {  // read_cdef: first non-skip block of the 64x64
        for (int i = F.cdefBits - 1; i >= 0; i--) o.bit((k.cdef_idx >> i) & 1);
        w.cdefDone = 1;
    }
    if (F.dq && w.firstInSb && !(bsize == AV1G_BLOCK_64X64 && k.skip)) {  // read_delta_qindex
        const int reduced = ((int)k.sb_qindex - w.curQ) / (1 << F.dqRes);
        const int a = reduced < 0 ? -reduced : reduced;
        o.sym(CID(delta_q), min(a, (int)AV1G_DELTA_Q_SMALL), AV1G_DELTA_Q_SMALL + 1);
        if (a >= AV1G_DELTA_Q_SMALL) {
            int rem = 1;
            while (((a - 1) >> (rem + 1)) > 0) rem++;
            for (int i = 2; i >= 0; i--) o.bit(((rem - 1) >> i) & 1);
            const int bits = (a - 1) - (1 << rem);
            for (int i = rem - 1; i >= 0; i--) o.bit((bits >> i) & 1);
        }
        if (a) o.bit(reduced < 0);
        w.curQ = k.sb_qindex;
    }
    w.firstInSb = 0;
    {
        const int am = AV1G_T(Intra_Mode_Context)[aU ? w.map(B.mYMode, r - 1, c) : AV1G_DC_PRED];
        const int lm = AV1G_T(Intra_Mode_Context)[aL ? w.map(B.mYMode, r, c - 1) : AV1G_DC_PRED];
        o.sym(CID(y_mode[am][lm]), k.y_mode, AV1G_INTRA_MODES);
    }
    if (bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(k.y_mode))
        o.sym(CID(angle_delta[k.y_mode - AV1G_V_PRED]), k.angle_delta_y + 3, 7);
    if (hasChroma) {
        if (av1g_cfl_allowed(bsize)) o.sym(CID(uv_mode_cfl_allowed[k.y_mode]), k.uv_mode, 14);
        else o.sym(CID(uv_mode_cfl_not_allowed[k.y_mode]), k.uv_mode, 13);
        if (k.uv_mode == AV1G_UV_CFL_PRED) {
            const int sU = k.cfl_alpha_u == 0 ? 0 : k.cfl_alpha_u < 0 ? 1 : 2;
            const int sV = k.cfl_alpha_v == 0 ? 0 : k.cfl_alpha_v < 0 ? 1 : 2;
            o.sym(CID(cfl_sign), sU * 3 + sV - 1, 8);
            if (sU) o.sym(CID(cfl_alpha[(sU - 1) * 3 + sV]), (k.cfl_alpha_u < 0 ? -k.cfl_alpha_u : k.cfl_alpha_u) - 1, 16);
            if (sV) o.sym(CID(cfl_alpha[(sV - 1) * 3 + sU]), (k.cfl_alpha_v < 0 ? -k.cfl_alpha_v : k.cfl_alpha_v) - 1, 16);
        }
        if (bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(k.uv_mode))
            o.sym(CID(angle_delta[k.uv_mode - AV1G_V_PRED]), k.angle_delta_uv + 3, 7);
    }
    if (F.sct && bsize >= AV1G_BLOCK_8X8 && bw4 <= 16 && bh4 <= 16) {
        const int bsizeCtx = AV1G_T(Mi_Width_Log2)[bsize] + AV1G_T(Mi_Height_Log2)[bsize] - 2;
        if (k.y_mode == AV1G_DC_PRED) o.sym(CID(palette_y_mode[bsizeCtx][0]), 0, 2);
        if (hasChroma && k.uv_mode == AV1G_DC_PRED) o.sym(CID(palette_uv_mode[0]), 0, 2);
    }
    if (F.fi && k.y_mode == AV1G_DC_PRED && bw4 <= 8 && bh4 <= 8) {  // filter_intra_mode_info
        o.sym(CID(filter_intra[bsize]), k.filter_intra != 0, 2);
        if (k.filter_intra) o.sym(CID(filter_intra_mode), k.filter_intra - 1, 5);
    }
    if (F.txsel && bsize > AV1G_BLOCK_4X4) {
        const int maxRect = AV1G_T(Max_Tx_Size_Rect)[bsize];
        const int maxTxDepth = AV1G_T(Max_Tx_Depth)[bsize];
        const int aboveW = aU ? AV1G_T(Tx_Width)[w.map(B.mTx, r - 1, c)] : 0;
        const int leftH = aL ? AV1G_T(Tx_Height)[w.map(B.mTx, r, c - 1)] : 0;
        const int ctx = (aboveW >= AV1G_T(Tx_Width)[maxRect]) + (leftH >= AV1G_T(Tx_Height)[maxRect]);
        if (maxTxDepth == 4) o.sym(CID(tx_64x64[ctx]), k.tx_depth, 3);
        else if (maxTxDepth == 3) o.sym(CID(tx_32x32[ctx]), k.tx_depth, 3);
        else if (maxTxDepth == 2) o.sym(CID(tx_16x16[ctx]), k.tx_depth, 3);
        else o.sym(CID(tx_8x8[ctx]), k.tx_depth, 2);
    }
    if (!w.emit) B.count[item] = o.n;
}

// decode_partition's pre-order over an explicit stack (Metal has no recursion): a split pushes its
// four quadrants, every other partition codes its blocks in order. Each node leaves at most three
// siblings pending, so four levels below the 64x64 need at most 13 entries.
static void ent_walk(thread EntWalk &w, int r0, int c0) {
    constant GaEntFrame &F = *w.F;
    constant GaEntBufs &B = *w.B;
    short sr[16], sc[16];
    uint8_t ss[16];
    int sp = 0;
    sr[0] = (short)r0; sc[0] = (short)c0; ss[0] = AV1G_BLOCK_64X64; sp = 1;
    while (sp > 0) {
        sp--;
        const int r = sr[sp], c = sc[sp], bSize = ss[sp];
        if (r >= F.MiRows || c >= F.MiCols) continue;
        const int hf = av1g_bw4(bSize) >> 1, quarter = hf >> 1;
        const int hasRows = (r + hf) < F.MiRows, hasCols = (c + hf) < F.MiCols;
        int p;
        if (w.cursor >= w.end) { ent_fail(B, GA_ENT_ERR_ORDER); return; }
        if (bSize < AV1G_BLOCK_8X8) {
            p = AV1G_PARTITION_NONE;
        } else {
            p = ent_derive(w, r, c, bSize, hasRows, hasCols);
            const int bsl = AV1G_T(Mi_Width_Log2)[bSize];
            const int above = w.inside(r - 1, c) && AV1G_T(Mi_Width_Log2)[w.map(B.mMiSize, r - 1, c)] < bsl;
            const int left = w.inside(r, c - 1) && AV1G_T(Mi_Height_Log2)[w.map(B.mMiSize, r, c - 1)] < bsl;
            const int ctx = left * 2 + above;
            const uint32_t cid = bsl == 1 ? CID(partition_w8[ctx]) : bsl == 2 ? CID(partition_w16[ctx])
                               : bsl == 3 ? CID(partition_w32[ctx]) : CID(partition_w64[ctx]);
            if (hasRows && hasCols) w.pend[w.npend++] = av1g_sym_pack(AV1G_SYM_ADAPT, cid, p, bsl == 1 ? 4 : 10);
            else if (hasCols) w.pend[w.npend++] = av1g_sym_pack(AV1G_SYM_SPLIT_OR_HORZ, cid, p == AV1G_PARTITION_SPLIT, 2);
            else if (hasRows) w.pend[w.npend++] = av1g_sym_pack(AV1G_SYM_SPLIT_OR_VERT, cid, p == AV1G_PARTITION_SPLIT, 2);
        }
        const int sub = AV1G_T(Partition_Subsize)[p][bSize];
        const int spl = AV1G_T(Partition_Subsize)[AV1G_PARTITION_SPLIT][bSize];
        if (p == AV1G_PARTITION_SPLIT) {  // pushed in reverse: the top-left quadrant comes next
            sr[sp] = (short)(r + hf); sc[sp] = (short)(c + hf); ss[sp++] = (uint8_t)sub;
            sr[sp] = (short)(r + hf); sc[sp] = (short)c; ss[sp++] = (uint8_t)sub;
            sr[sp] = (short)r; sc[sp] = (short)(c + hf); ss[sp++] = (uint8_t)sub;
            sr[sp] = (short)r; sc[sp] = (short)c; ss[sp++] = (uint8_t)sub;
            continue;
        }
        int br[4], bc[4], bs[4], nb = 0;
#define ENT_B(rr, cc, ss_) do { br[nb] = (rr); bc[nb] = (cc); bs[nb] = (ss_); nb++; } while (0)
        switch (p) {
        case AV1G_PARTITION_NONE: ENT_B(r, c, sub); break;
        case AV1G_PARTITION_HORZ: ENT_B(r, c, sub); if (hasRows) ENT_B(r + hf, c, sub); break;
        case AV1G_PARTITION_VERT: ENT_B(r, c, sub); if (hasCols) ENT_B(r, c + hf, sub); break;
        case AV1G_PARTITION_HORZ_A: ENT_B(r, c, spl); ENT_B(r, c + hf, spl); ENT_B(r + hf, c, sub); break;
        case AV1G_PARTITION_HORZ_B: ENT_B(r, c, sub); ENT_B(r + hf, c, spl); ENT_B(r + hf, c + hf, spl); break;
        case AV1G_PARTITION_VERT_A: ENT_B(r, c, spl); ENT_B(r + hf, c, spl); ENT_B(r, c + hf, sub); break;
        case AV1G_PARTITION_VERT_B: ENT_B(r, c, sub); ENT_B(r, c + hf, spl); ENT_B(r + hf, c + hf, spl); break;
        case AV1G_PARTITION_HORZ_4:
            for (int i = 0; i < 4; i++) if (i < 3 || r + quarter * 3 < F.MiRows) ENT_B(r + quarter * i, c, sub);
            break;
        default:
            for (int i = 0; i < 4; i++) if (i < 3 || c + quarter * 3 < F.MiCols) ENT_B(r, c + quarter * i, sub);
            break;
        }
#undef ENT_B
        for (int i = 0; i < nb; i++) ent_block(w, br[i], bc[i], bs[i]);
    }
}

kernel void e_sbsym(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                    constant uint32_t &emit [[buffer(2)]], uint s [[thread_position_in_grid]]) {
    if (s >= F.nSb) return;
    if (emit && B.off[F.nBlocks + F.nTxb] > F.symCap) return;
    const GaEntSb sb = B.sbs[s];
    EntWalk w;
    w.F = &F;
    w.T = B.tiles[sb.tile];
    w.B = &B;
    w.cursor = sb.firstBlock;
    w.end = sb.endBlock;
    w.emit = emit != 0;
    w.npend = 0;
    w.curQ = sb.qBefore;
    w.firstInSb = 1;
    w.cdefDone = 0;
    if (sb.firstBlock >= sb.endBlock) { ent_fail(B, GA_ENT_ERR_ORDER); return; }
    ent_walk(w, sb.r, sb.c);
    if (w.cursor != w.end) ent_fail(B, GA_ENT_ERR_ORDER);
}

// ---------------------------------------------------------------------------
// exclusive scan of n uint32s (n <= 2^31), one threadgroup: each thread sums a run, the runs'
// sums are scanned in threadgroup memory, then each thread writes its run's prefixes

kernel void e_scan(device const uint32_t *in [[buffer(0)]], device uint32_t *out [[buffer(1)]],
                   constant uint32_t &n [[buffer(2)]], uint tid [[thread_position_in_threadgroup]],
                   uint tgs [[threads_per_threadgroup]]) {
    threadgroup uint32_t part[1024];
    const uint32_t per = (n + tgs - 1) / tgs, b = min(tid * per, n), e = min(b + per, n);
    uint32_t s = 0;
    for (uint32_t i = b; i < e; i++) s += in[i];
    part[tid] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint32_t d = 1; d < tgs; d <<= 1) {
        const uint32_t v = tid >= d ? part[tid - d] : 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        part[tid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint32_t run = tid ? part[tid - 1] : 0;
    for (uint32_t i = b; i < e; i++) {
        const uint32_t v = in[i];
        out[i] = run;
        run += v;
    }
}

// per tile: symbol range, q, payload capacity (symbols / 2 + 256 bytes)
kernel void e_tilerange(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                        uint t [[thread_position_in_grid]]) {
    const uint32_t nTiles = F.nTiles;
    if (t >= nTiles) return;
    const uint32_t nB = F.nBlocks, nItems = F.nBlocks + F.nTxb;
    const uint32_t total = B.off[nItems];
    const bool ovf = total > F.symCap;
    auto itemOf = [&](uint32_t b) -> uint32_t { return b < nB ? B.off[b + B.blockTxbG[b]] : total; };
    uint32_t b = itemOf(B.tiles[t].firstBlock), e = itemOf(B.tiles[t].endBlock);
    if (ovf || e < b) b = e = 0;
    B.tb[t] = b;
    B.te[t] = e;
    B.tq[t] = F.qidx;
    B.capArr[t] = (e - b) / 2 + 256;
    if (t == 0) {
        B.capArr[nTiles] = 0;
        B.status->symbols = total;
        B.status->symbolCapacity = F.symCap;
        if (ovf) ent_fail(B, GA_ENT_ERR_SYMBOLS);
    }
}

// ---------------------------------------------------------------------------
// the windowed entropy coder
//
// The range coder: libaom's od_ec with the 64-bit window (aom_dsp/entenc.c: up to 7 bytes flushed
// at once when 40+ bits are pending, carries propagated backwards into the output at flush time),
// fed precomputed (fl, fh) words. libaom documents it as bit-identical to the 32-bit precarry
// encoder (av1g_ec in entenc.h, which the CPU writer uses).
struct EntRc {
    uint64_t low;
    uint32_t rng, offs, cap;
    int cnt, ovf;
    device uint8_t *out;
    void init(device uint8_t *o, uint32_t c) { low = 0; rng = 0x8000; cnt = -9; offs = 0; cap = c; ovf = 0; out = o; }
    void carry_bwd(uint32_t k) {  // propagate_carry_bwd(out, k)
        for (;;) {
            const uint32_t x = out[k] + 1u;
            out[k] = (uint8_t)x;
            if (x <= 0xFFu || k == 0) break;
            k--;
        }
    }
    void flush(thread int &c, int s) {  // the s >= 40 branch of od_ec_enc_normalize
        const int nb = (s >> 3) + 1;
        c += 24 - (nb << 3);
        uint64_t output = low >> c;
        low &= ((uint64_t)1 << c) - 1;
        const uint64_t mask = (uint64_t)1 << (nb << 3);
        const bool carry = (output & mask) != 0;
        output &= mask - 1;
        if (offs + (uint32_t)nb > cap) { ovf = 1; offs = 0; }
        for (int i = 0; i < nb; i++) out[offs + i] = (uint8_t)(output >> ((nb - 1 - i) << 3));
        if (carry && offs > 0) carry_bwd(offs - 1);
        offs += (uint32_t)nb;
    }
    int done() {
        const uint64_t m = 0x3FFF;
        uint64_t e = ((low + m) & ~m) | (m + 1);
        int c = cnt, s = 10 + c;
        if (s > 0) {
            uint64_t n = ((uint64_t)1 << (c + 16)) - 1;
            do {
                if (offs >= cap) { ovf = 1; break; }
                const uint32_t val = (uint32_t)(e >> (c + 16)) & 0xFFFFu;
                out[offs] = (uint8_t)val;
                if ((val & 0x100u) && offs > 0) carry_bwd(offs - 1);
                offs++;
                e &= n;
                s -= 8;
                c -= 8;
                n >>= 8;
            } while (s > 0);
        }
        return ovf ? -1 : (int)offs;
    }
    // od_ec_encode_q15 + normalize; u = r when fl >= 32768 (then low is unchanged and r -= v).
    // cw: bit 31 = (fl < 32768), bits 21..30 fl >> 6, bits 11..20 fh >> 6, bits 0..4 nsyms - 1 - s.
    void code(uint32_t cw) {
        uint32_t r = rng;
        const uint32_t r8 = r >> 8, nms4 = 4u * (cw & 31u);
        const uint32_t v = ((r8 * ((cw >> 11) & 1023u)) >> 1) + nms4;
        const uint32_t uq = ((r8 * ((cw >> 21) & 1023u)) >> 1) + nms4 + 4u;
        const uint32_t u = (cw >> 31) ? uq : r;
        uint64_t l = low + (r - u);
        r = u - v;
        const int d = (int)clz(r) - 16;
        int c = cnt;
        int s = c + d;
        if (s >= 40) {
            low = l;
            flush(c, s);
            l = low;
            s = c + d - 24;
        }
        low = l << d;
        rng = r << d;
        cnt = s;
    }
};

static inline uint32_t ent_coded_word(uint32_t fl, uint32_t fh, uint32_t nms) {
    return (fl < 32768u ? 0x80000000u : 0u) | ((fl >> 6) << 21) | ((fh >> 6) << 11) | nms;
}

// value of cr[idx] for a runtime idx without thread memory
static inline uint32_t ent_sel16(thread const uint32_t (&cr)[16], uint32_t idx) {
    uint32_t v = 0;
#pragma unroll
    for (int i = 0; i < 16; i++) v = (uint32_t)i == idx ? cr[i] : v;
    return v;
}

#define GA_ENT_CDF_WORDS (sizeof(av1g_cdfs) / 16)

kernel void e_entropy(constant GaEntFrame &F [[buffer(0)]], constant GaEntBufs &B [[buffer(1)]],
                      uint t [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]]) {
    threadgroup uint4 sh4[GA_ENT_CDF_WORDS];
    threadgroup uint32_t ring[32];  // the window's coded words
    threadgroup uint32_t sw[32];    // per lane: s | kind << 8
    threadgroup uint16_t *cdf = (threadgroup uint16_t *)sh4;
    {
        device const uint4 *src = (device const uint4 *)B.cdfDefaults + GA_ENT_CDF_WORDS * av1g_coeff_cdf_q_ctx(B.tq[t]);
        for (uint i = lane; i < GA_ENT_CDF_WORDS; i += 32) sh4[i] = src[i];
        simdgroup_barrier(mem_flags::mem_threadgroup);
    }
    const uint32_t b = B.tb[t], e = B.te[t];
    const uint32_t nWin = (e - b + 31) / 32;
    EntRc rc;
    if (lane == 0) rc.init(B.staging + B.capOff[t], B.capOff[t + 1] - B.capOff[t]);
    for (uint32_t w = 0; w < nWin; w++) {
        const uint32_t w0 = b + 32 * w;
        const uint32_t nv = min(32u, e - w0);
        const uint32_t word = lane < nv ? B.syms[w0 + lane] : 0u;
        // adaptation: symbols sharing a CDF form a group; its first lane applies the group's
        // updates in stream order with the CDF in registers
        const uint32_t kind = lane < nv ? word >> 24 : AV1G_SYM_BOOL;
        const uint32_t s = (word >> 16) & 15u, off = word & 0xFFFFu;
        const uint32_t key = kind == AV1G_SYM_BOOL ? 0x10000u | lane : off;
        uint peers = kind == AV1G_SYM_BOOL ? 1u << lane : 0u;  // a bool is its own group
        for (;;) {  // __match_any_sync(key), over the CDF groups
            const uint open = ent_ballot(peers == 0);
            if (!open) break;
            const uint32_t lk = simd_shuffle(key, (ushort)ctz(open));
            const uint m = ent_ballot(key == lk);
            if (key == lk) peers = m;
        }
        sw[lane] = s | (kind << 8);
        if (kind == AV1G_SYM_BOOL) ring[lane] = ent_coded_word(s ? 16384u : 32768u, s ? 0u : 16384u, 1u - (s & 1u));
        simdgroup_barrier(mem_flags::mem_threadgroup);
        if (kind != AV1G_SYM_BOOL && (peers & ((1u << lane) - 1u)) == 0) {
            // the CDF's alphabet: a split_or_* word carries the bool's N; its partition CDF has 10
            const uint32_t N = kind == AV1G_SYM_ADAPT ? ((word >> 20) & 15u) + 1 : 10u;
            threadgroup uint16_t *c = cdf + off;
            uint32_t cr[16];
#pragma unroll
            for (int i = 0; i < 16; i++) cr[i] = (uint32_t)i < N ? c[i] : 0u;
            uint32_t cnt = c[N];
            uint m = peers;
            while (m) {
                const int j = ctz(m);
                m &= m - 1;
                const uint32_t x = sw[j], sj = x & 15u;
                if ((x >> 8) == AV1G_SYM_ADAPT) {
                    ring[j] = ent_coded_word(sj ? 32768u - ent_sel16(cr, sj - 1) : 32768u, 32768u - ent_sel16(cr, sj), N - 1 - sj);
                    const int rate = 3 + (cnt > 15) + (cnt > 31) + (N >= 4 ? 2 : 1);
                    // all 16 entries unconditionally (straight-line code): cr[N-1] == 32768 stays
                    // 32768, entries >= N are never read nor written back
#pragma unroll
                    for (int i = 0; i < 16; i++) {
                        const uint32_t y = cr[i];
                        cr[i] = (uint32_t)i < sj ? y - (y >> rate) : y + ((32768u - y) >> rate);
                    }
                    cnt += cnt < 32;
                } else {  // split_or_horz / split_or_vert: read-only use of the partition CDF
#define P_(k) (cr[k] - ((k) > 0 ? cr[(k) > 0 ? (k) - 1 : 0] : 0u))
                    const uint32_t psum = (x >> 8) == AV1G_SYM_SPLIT_OR_HORZ
                        ? P_(AV1G_PARTITION_VERT) + P_(AV1G_PARTITION_SPLIT) + P_(AV1G_PARTITION_HORZ_A) +
                              P_(AV1G_PARTITION_VERT_A) + P_(AV1G_PARTITION_VERT_B) + P_(AV1G_PARTITION_VERT_4)
                        : P_(AV1G_PARTITION_HORZ) + P_(AV1G_PARTITION_SPLIT) + P_(AV1G_PARTITION_HORZ_A) +
                              P_(AV1G_PARTITION_HORZ_B) + P_(AV1G_PARTITION_VERT_A) + P_(AV1G_PARTITION_HORZ_4);
#undef P_
                    ring[j] = ent_coded_word(sj ? psum : 32768u, sj ? 0u : psum, 1u - sj);
                }
            }
#pragma unroll
            for (int i = 0; i < 15; i++)
                if ((uint32_t)i + 1 < N) c[i] = (uint16_t)cr[i];
            c[N] = (uint16_t)cnt;
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);
        if (lane == 0)
            for (uint32_t j = 0; j < nv; j++) rc.code(ring[j]);
        simdgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) {
        const int n = rc.done();
        B.sizes[t] = n < 0 ? 0 : (uint32_t)n;
        if (n < 0) ent_fail(B, GA_ENT_ERR_OUTPUT);
    }
}

// the default CDFs, one image per coefficient q context
kernel void e_cdf_defaults(device uint16_t *img [[buffer(0)]], uint q [[thread_position_in_grid]]) {
    if (q >= 4) return;
    av1g_cdfs_init((device av1g_cdfs *)img + q, q == 0 ? 20 : q == 1 ? 60 : q == 2 ? 120 : 255);
}
