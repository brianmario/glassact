// Random-decision fuzzer for av1core.
//
// Generates random *legal* DecisionRecords (random sizes, partitions, modes,
// angle deltas, CFL alphas, tx sizes/types, sparse coefficients incl. Golomb-range
// magnitudes, skip blocks, tiles, delta-q, QM, filter intra, edge filter,
// deblocking + CDEF), encodes them with av1core and checks
// that a decoder reproduces av1core's reconstruction byte for byte.
//
// Glass Act: from av1gpu's tests/fuzz.cpp (BSD-2, see Sources/AV1Core/LICENSE):
// the generator only (Rng, Gen, make_case). The decoders run in-process from
// Swift (AV1CoreTests, vendored libaom) instead of dav1d/aomdec via system().
// post-filter path coverage (counted when the fuzzer re-runs the shared filters itself)
static unsigned long long g_pfStat[16];
#if defined(__CUDA_ARCH__)
#define AV1G_PF_STAT(kind) ((void)0)
#else
#define AV1G_PF_STAT(kind) (g_pfStat[(kind)]++)
#endif
#include "av1g/postfilter.h"
#include "av1g/av1g.h"
#include "av1g/blockinfo.h"
#include "av1g/dsp.h"
#include "av1g/internal.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>


struct Rng {
    uint64_t s;
    static uint64_t mix(uint64_t z) {
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    // hash the seed so that streams of consecutive seeds are not shifted copies
    explicit Rng(uint64_t seed) : s(mix(mix(seed + 0x632BE59BD9B4E019ull))) { next(); }
    uint64_t next() {  // splitmix64
        uint64_t z = (s += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    int range(int lo, int hi) { return lo + (int)(next() % (uint64_t)(hi - lo + 1)); }  // inclusive
    bool chance(int pct) { return (int)(next() % 100) < pct; }
};

struct Coverage {
    uint64_t part[22][10] = {};        // [node bsize][partition]
    uint64_t bsize[22] = {};
    uint64_t ymode[13][7] = {};        // [mode][angle delta + 3]
    uint64_t uvmode[14][7] = {};
    uint64_t cflSigns[9] = {};
    uint64_t txLuma[19][16] = {};      // coded (eob > 0) luma tx blocks
    uint64_t txChroma[19] = {};
    uint64_t depth[22][3] = {};
    uint64_t fiMode[5] = {}, fiFrames = 0, efFrames = 0, efDirBlocks = 0;
    uint64_t sct = 0, qm = 0, qmSep = 0, qmLevel[16] = {}, dq = 0, dqRes[4] = {}, dqBigJump = 0, dqSkipSb = 0;
    uint64_t lf = 0, lfChromaOff = 0, lfSharp[8] = {}, cdef = 0, cdefBits[4] = {}, cdefDamp[4] = {}, cdefSec4 = 0, pfBoth = 0;
    uint64_t golomb = 0, maxMag = 0, skip = 0, mono = 0, deltaq = 0, sepuv = 0, multiTile = 0, edgeForced = 0;
    uint32_t maxTileCols = 0, maxTileRows = 0;
};
static Coverage cov;

struct Gen {
    Rng &rng;
    bool m2;
    int W, H, MiCols, MiRows, mono, txSelect, reduced;
    std::vector<av1g_block> blocks;
    int maxDepthBias;
    int dqBias = 0;
    int pfSmooth = 0;  // post-filter cases: more skip blocks (flat areas reach the wide filters)
    int fi = 0;  // enable_filter_intra  // delta-q cases: produce whole-SB skip blocks (no delta coded for them)
    av1g_tiles tiles;

    Gen(Rng &r, bool m2_) : rng(r), m2(m2_) {}

    void make_block(int r, int c, int bs) {
        av1g_block b;
        memset(&b, 0, sizeof b);
        b.mi_row = (uint16_t)r;
        b.mi_col = (uint16_t)c;
        b.bsize = (uint8_t)bs;
        if (m2) {
            b.y_mode = AV1G_DC_PRED;
            b.uv_mode = AV1G_DC_PRED;
            b.skip = rng.chance(10);
            blocks.push_back(b);
            return;
        }
        b.skip = rng.chance(bs == AV1G_BLOCK_64X64 && dqBias ? 60 : pfSmooth ? 45 : 15);
        cov.skip += b.skip;
        b.y_mode = (uint8_t)rng.range(0, 12);
        if (bs >= AV1G_BLOCK_8X8 && av1g_is_directional(b.y_mode) && rng.chance(70)) b.angle_delta_y = (int8_t)rng.range(-3, 3);
        if (txSelect && bs > AV1G_BLOCK_4X4) b.tx_depth = (uint8_t)rng.range(0, av1g_max_tx_depth(bs));
        if (av1g_has_chroma(bs, r, c, mono)) {
            int maxuv = av1g_cfl_allowed(bs) ? 13 : 12;
            b.uv_mode = (uint8_t)rng.range(0, maxuv);
            if (av1g_cfl_allowed(bs) && rng.chance(20)) b.uv_mode = AV1G_UV_CFL_PRED;
            if (b.uv_mode == AV1G_UV_CFL_PRED) {
                do {
                    b.cfl_alpha_u = (int8_t)(rng.chance(25) ? 0 : rng.range(-16, 16));
                    b.cfl_alpha_v = (int8_t)(rng.chance(25) ? 0 : rng.range(-16, 16));
                } while (b.cfl_alpha_u == 0 && b.cfl_alpha_v == 0);
            }
            if (bs >= AV1G_BLOCK_8X8 && av1g_is_directional(b.uv_mode) && rng.chance(70)) b.angle_delta_uv = (int8_t)rng.range(-3, 3);
            cov.uvmode[b.uv_mode][b.angle_delta_uv + 3]++;
            if (b.uv_mode == AV1G_UV_CFL_PRED) {
                int su = b.cfl_alpha_u == 0 ? 0 : b.cfl_alpha_u < 0 ? 1 : 2, sv = b.cfl_alpha_v == 0 ? 0 : b.cfl_alpha_v < 0 ? 1 : 2;
                cov.cflSigns[su * 3 + sv - 1]++;
            }
        }
        if (fi && b.y_mode == AV1G_DC_PRED && av1g_bw4(bs) <= 8 && av1g_bh4(bs) <= 8 && rng.chance(50)) {
            b.filter_intra = (uint8_t)rng.range(1, 5);
            cov.fiMode[b.filter_intra - 1]++;
        }
        cov.ymode[b.y_mode][b.angle_delta_y + 3]++;
        cov.bsize[bs]++;
        cov.depth[bs][b.tx_depth]++;
        blocks.push_back(b);
    }

    int pick_partition(int bs, int hasRows, int hasCols, int depth) {
        if (m2) {
            if (!(hasRows && hasCols)) return AV1G_PARTITION_SPLIT;
            return bs > AV1G_BLOCK_16X16 ? AV1G_PARTITION_SPLIT : AV1G_PARTITION_NONE;
        }
        if (hasRows && hasCols) {
            if (bs == AV1G_BLOCK_8X8) return rng.range(0, 3);
            if (bs == AV1G_BLOCK_64X64 && dqBias && rng.chance(25)) return AV1G_PARTITION_NONE;
            // bias: split often at large sizes, use every type
            int pSplit = bs == AV1G_BLOCK_64X64 ? 55 : bs == AV1G_BLOCK_32X32 ? 40 : 25;
            pSplit = pSplit * maxDepthBias / 2;
            if (rng.chance(pSplit)) return AV1G_PARTITION_SPLIT;
            int p = rng.range(0, 9);
            return p;
        }
        if (hasCols) return rng.chance(50) ? AV1G_PARTITION_HORZ : AV1G_PARTITION_SPLIT;
        if (hasRows) return rng.chance(50) ? AV1G_PARTITION_VERT : AV1G_PARTITION_SPLIT;
        return AV1G_PARTITION_SPLIT;
    }

    void partition(int r, int c, int bSize, int depth) {
        if (r >= MiRows || c >= MiCols) return;
        const int num4x4 = av1g_bw4(bSize), half = num4x4 >> 1, quarter = half >> 1;
        const int hasRows = (r + half) < MiRows, hasCols = (c + half) < MiCols;
        int p = bSize < AV1G_BLOCK_8X8 ? AV1G_PARTITION_NONE : pick_partition(bSize, hasRows, hasCols, depth);
        if (bSize >= AV1G_BLOCK_8X8) { cov.part[bSize][p]++; if (!(hasRows && hasCols)) cov.edgeForced++; }
        const int sub = AV1G_T(Partition_Subsize)[p][bSize];
        const int sp = AV1G_T(Partition_Subsize)[AV1G_PARTITION_SPLIT][bSize];
        switch (p) {
        case AV1G_PARTITION_NONE: make_block(r, c, sub); break;
        case AV1G_PARTITION_HORZ: make_block(r, c, sub); if (hasRows) make_block(r + half, c, sub); break;
        case AV1G_PARTITION_VERT: make_block(r, c, sub); if (hasCols) make_block(r, c + half, sub); break;
        case AV1G_PARTITION_SPLIT:
            partition(r, c, sub, depth + 1); partition(r, c + half, sub, depth + 1);
            partition(r + half, c, sub, depth + 1); partition(r + half, c + half, sub, depth + 1);
            break;
        case AV1G_PARTITION_HORZ_A: make_block(r, c, sp); make_block(r, c + half, sp); make_block(r + half, c, sub); break;
        case AV1G_PARTITION_HORZ_B: make_block(r, c, sub); make_block(r + half, c, sp); make_block(r + half, c + half, sp); break;
        case AV1G_PARTITION_VERT_A: make_block(r, c, sp); make_block(r + half, c, sp); make_block(r, c + half, sub); break;
        case AV1G_PARTITION_VERT_B: make_block(r, c, sub); make_block(r, c + half, sp); make_block(r + half, c + half, sp); break;
        case AV1G_PARTITION_HORZ_4:
            for (int i = 0; i < 4; i++) if (i < 3 || r + quarter * 3 < MiRows) make_block(r + quarter * i, c, sub);
            break;
        default:
            for (int i = 0; i < 4; i++) if (i < 3 || c + quarter * 3 < MiCols) make_block(r, c + quarter * i, sub);
            break;
        }
    }

    void gen_blocks() {
        for (uint32_t tr = 0; tr < tiles.rows; tr++)
            for (uint32_t tc = 0; tc < tiles.cols; tc++)
                for (uint32_t r = tiles.mi_row_starts[tr]; r < tiles.mi_row_starts[tr + 1]; r += 16)
                    for (uint32_t c = tiles.mi_col_starts[tc]; c < tiles.mi_col_starts[tc + 1]; c += 16)
                        partition(r, c, AV1G_BLOCK_64X64, 0);
    }

    // random sparse coefficients for one tx block
    void fill_coeffs(int16_t *q, int txSz, int plane, int txType, int style) {
        const int n = av1g_tx_coeffs(txSz);
        memset(q, 0, sizeof(int16_t) * n);
        if (rng.chance(25)) return;  // all zero
        const uint16_t *scan = av1g_get_scan(txSz, txType);
        int eob;
        int r = rng.range(0, 99);
        if (r < 30) eob = rng.range(1, n < 4 ? n : 4);
        else if (r < 70) eob = rng.range(1, n < 32 ? n : 32);
        else eob = rng.range(1, n);
        int density = rng.range(5, 100);
        for (int c = 0; c < eob; c++) {
            if (c != eob - 1 && !rng.chance(density)) continue;
            int mag;
            int m = rng.range(0, 999);
            if (m < 600) mag = 1;
            else if (m < 800) mag = rng.range(2, 3);
            else if (m < 920) mag = rng.range(4, 15);
            else if (m < 985) mag = rng.range(16, 300);
            else if (m < 997) mag = rng.range(300, 5000);
            else mag = rng.range(5000, 32767);
            if (style == 1 && mag > 40) mag = 40;
            q[scan[c]] = (int16_t)(rng.chance(50) ? -mag : mag);
        }
    }
};


struct FuzzCase {
    av1g_decision_record rec;
    std::vector<av1g_block> blocks;
    std::vector<uint32_t> btx;
    std::vector<av1g_txb> txb;
    std::vector<int16_t> coeffs;
};

// Build the random legal record of seed cs (deterministic).
static bool make_case(uint64_t cs, bool m2, int maxdim, int bigPct, FuzzCase &fc) {
    Rng rng(cs);
    Gen g(rng, m2);
    // ---- frame parameters ----
    int W, H;
    int sz = rng.range(0, 99);
    static const int special[][2] = {{1, 1}, {7, 13}, {65, 65}, {64, 64}, {8, 8}, {2, 3}, {13, 7}, {16, 16}, {72, 40}, {129, 1}};
    if (sz < 10) { int k = rng.range(0, 9); W = special[k][0]; H = special[k][1]; }
    else if (sz < 30) { W = rng.range(1, 40); H = rng.range(1, 40); }
    else if (sz < 100 - bigPct) { W = rng.range(1, maxdim); H = rng.range(1, maxdim); }
    else {  // forced tiles: wider than 4096 or area > 4096*2304
        if (rng.chance(70)) { W = rng.range(4097, 9000); H = rng.range(1, 80); }
        else { W = rng.range(3000, 4096); H = rng.range(2400, 2600); }
    }
    av1g_decision_record &rec = fc.rec;
    memset(&rec, 0, sizeof rec);
    rec.fp.version = AV1G_DECISIONS_VERSION;
    rec.fp.width = W;
    rec.fp.height = H;
    rec.fp.monochrome = m2 ? 0 : rng.chance(15);
    rec.fp.base_q_idx = (uint8_t)rng.range(1, 255);
    rec.fp.tx_mode_select = m2 ? 0 : rng.chance(60);
    rec.fp.reduced_tx_set = m2 ? 0 : rng.chance(30);
    rec.fp.tile_cols_log2 = -1;
    rec.fp.tile_rows_log2 = -1;
    rec.fp.allow_screen_content_tools = m2 ? 0 : rng.chance(15);
    if (!m2 && rng.chance(15)) {
        rec.fp.delta_q_y_dc = (int8_t)rng.range(-20, 20);
        rec.fp.delta_q_u_dc = (int8_t)rng.range(-20, 20);
        rec.fp.delta_q_u_ac = (int8_t)rng.range(-20, 20);
        if (rng.chance(50)) { rec.fp.delta_q_v_dc = (int8_t)rng.range(-20, 20); rec.fp.delta_q_v_ac = (int8_t)rng.range(-20, 20); }
        else { rec.fp.delta_q_v_dc = rec.fp.delta_q_u_dc; rec.fp.delta_q_v_ac = rec.fp.delta_q_u_ac; }
    }
    if (!m2 && rng.chance(30)) {
        rec.fp.using_qmatrix = 1;
        rec.fp.qm_y = (uint8_t)rng.range(0, 15);
        rec.fp.qm_u = (uint8_t)rng.range(0, 15);
        rec.fp.qm_v = rng.chance(50) ? rec.fp.qm_u : (uint8_t)rng.range(0, 15);
    }
    if (!m2 && rng.chance(35)) rec.fp.enable_filter_intra = 1;
    if (!m2 && rng.chance(35)) rec.fp.enable_intra_edge_filter = 1;
    if (!m2 && rng.chance(30)) {
        rec.fp.delta_q_present = 1;
        rec.fp.delta_q_res = (uint8_t)rng.range(0, 3);
    }
    // optional extra tiles for moderately sized pictures
    av1g_tiles mt;
    av1g_tile_layout(W, H, -1, -1, &mt);
    if (!m2 && rng.chance(15)) {
        av1g_tiles t2;
        int cl = mt.cols_log2 + rng.range(0, 2), rl = rng.range(0, 2);
        if (av1g_tile_layout(W, H, cl, rl, &t2) == AV1G_OK) { rec.fp.tile_cols_log2 = (int8_t)cl; rec.fp.tile_rows_log2 = (int8_t)rl; }
    }
    av1g_tile_layout(W, H, rec.fp.tile_cols_log2, rec.fp.tile_rows_log2, &g.tiles);
    // deblocking / CDEF parameters from their own stream (keeps the pre-M5.5 cases of each seed)
    Rng prng(cs ^ 0x5DEECE66Dull);
    if (!m2 && prng.chance(45)) {
        static const uint8_t hi[] = {63, 50, 40, 32, 24, 16, 8, 4};
        rec.fp.loop_filter_level[0] = (uint8_t)(prng.chance(50) ? hi[prng.range(0, 7)] : prng.range(0, 63));
        rec.fp.loop_filter_level[1] = (uint8_t)(prng.chance(20) ? 0 : prng.chance(50) ? rec.fp.loop_filter_level[0] : prng.range(0, 63));
        if (!rec.fp.loop_filter_level[0] && !rec.fp.loop_filter_level[1]) rec.fp.loop_filter_level[1] = 1;
        if (!rec.fp.monochrome) {
            rec.fp.loop_filter_level[2] = (uint8_t)(prng.chance(15) ? 0 : prng.range(0, 63));
            rec.fp.loop_filter_level[3] = (uint8_t)(prng.chance(15) ? 0 : prng.range(0, 63));
        }
        rec.fp.loop_filter_sharpness = (uint8_t)(prng.chance(50) ? 0 : prng.range(0, 7));
    }
    if (!m2 && prng.chance(45)) {
        static const uint8_t sec[4] = {0, 1, 2, 4};
        rec.fp.enable_cdef = 1;
        rec.fp.cdef_damping_minus_3 = (uint8_t)prng.range(0, 3);
        rec.fp.cdef_bits = (uint8_t)prng.range(0, 3);
        for (int i = 0; i < (1 << rec.fp.cdef_bits); i++) {
            rec.fp.cdef_y_pri[i] = (uint8_t)prng.range(0, 15);
            rec.fp.cdef_y_sec[i] = sec[prng.range(0, 3)];
            if (!rec.fp.monochrome) {
                rec.fp.cdef_uv_pri[i] = (uint8_t)prng.range(0, 15);
                rec.fp.cdef_uv_sec[i] = sec[prng.range(0, 3)];
            }
        }
    }
    g.pfSmooth = (rec.fp.loop_filter_level[0] || rec.fp.loop_filter_level[1] || rec.fp.enable_cdef) && prng.chance(50);
    g.W = W; g.H = H;
    g.MiCols = av1g_mi_cols(W); g.MiRows = av1g_mi_rows(H);
    g.mono = rec.fp.monochrome;
    g.txSelect = rec.fp.tx_mode_select;
    g.reduced = rec.fp.reduced_tx_set;
    g.maxDepthBias = rng.range(1, 3);
    g.dqBias = rec.fp.delta_q_present;
    g.fi = rec.fp.enable_filter_intra;
    g.gen_blocks();
    fc.blocks.swap(g.blocks);
    rec.n_blocks = (uint32_t)fc.blocks.size();
    rec.blocks = fc.blocks.data();
    fc.btx.assign(rec.n_blocks + 1, 0);
    rec.block_txb = fc.btx.data();
    av1g_layout(&rec, 0, 0);
    fc.txb.assign(rec.n_txb, av1g_txb());
    fc.coeffs.assign(rec.n_coeffs + 1, 0);
    rec.txb = fc.txb.data();
    rec.coeffs = fc.coeffs.data();
    if (av1g_layout(&rec, rec.n_txb, rec.n_coeffs) != AV1G_OK) { fprintf(stderr, "seed %llu: layout failed\n", (unsigned long long)cs); return false; }
    if (rec.fp.delta_q_present) {  // random per-SB qindex map, legalized
        const int sbCols = (g.MiCols + 15) >> 4, sbRows = (g.MiRows + 15) >> 4;
        std::vector<uint8_t> target((size_t)sbCols * sbRows), legal(target.size());
        const int mode = rng.range(0, 2);
        for (auto &t : target)
            t = (uint8_t)(mode == 0 ? rng.range(1, 255) : mode == 1 ? std::max(1, std::min(255, rec.fp.base_q_idx + rng.range(-12, 12)))
                                                              : (rng.chance(80) ? rec.fp.base_q_idx : rng.range(1, 255)));
        av1g_legalize_sb_qindex(rec.fp.base_q_idx, rec.fp.delta_q_res, target.data(), target.size(), legal.data());
        av1g_apply_sb_qindex(&rec, legal.data());
    }
    if (rec.fp.enable_cdef) {  // one random cdef_idx per 64x64 (all blocks of an SB share it)
        const int sbCols = (g.MiCols + 15) >> 4, sbRows = (g.MiRows + 15) >> 4;
        std::vector<int8_t> sbc((size_t)sbCols * sbRows);
        for (auto &v : sbc) v = (int8_t)prng.range(0, (1 << rec.fp.cdef_bits) - 1);
        for (uint32_t b = 0; b < rec.n_blocks; b++)
            rec.blocks[b].cdef_idx = sbc[(size_t)(rec.blocks[b].mi_row >> 4) * sbCols + (rec.blocks[b].mi_col >> 4)];
    }
    const int style = rng.chance(50) ? 1 : 0;
    for (uint32_t b = 0; b < rec.n_blocks; b++) {
        for (uint32_t t = rec.block_txb[b]; t < rec.block_txb[b + 1]; t++) {
            av1g_txb &x = rec.txb[t];
            int type = AV1G_DCT_DCT;
            if (x.plane == 0 && !m2) {
                int set = av1g_get_tx_set_intra(x.tx_size, rec.fp.reduced_tx_set);
                if (set > 0) {
                    do type = rng.range(0, 15); while (!av1g_tx_type_in_set_intra(set, type));
                }
                x.tx_type = (uint8_t)type;
            } else if (x.plane > 0) {
                type = av1g_chroma_tx_type(x.tx_size, rec.blocks[b].uv_mode, rec.fp.reduced_tx_set);
            }
            g.fill_coeffs(rec.coeffs + x.coeff_off, x.tx_size, x.plane, type, style);
        }
    }
    return true;
}


// ---- Glass Act: C API for the Swift tests (include/av1core_test.h) ----
#include "av1core_test.h"

struct av1t_case { FuzzCase fc; };

extern "C" av1t_case *av1t_case_make(uint64_t seed, int maxdim, int big_pct) {
    av1t_case *c = new av1t_case;
    if (!make_case(seed, false, maxdim, big_pct, c->fc)) { delete c; return nullptr; }
    return c;
}

extern "C" av1g_decision_record *av1t_case_record(av1t_case *c) { return &c->fc.rec; }

extern "C" void av1t_case_free(av1t_case *c) { delete c; }
