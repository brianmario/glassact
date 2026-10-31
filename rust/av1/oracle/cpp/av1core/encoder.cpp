// av1core backend: DecisionRecord <-> AV1 OBUs (+ exact reconstruction).
//
// One syntax walk, two directions.  The walk mirrors the AV1 spec syntax (5.9 /
// 5.11) element by element with the spec's context derivations (8.3.2).  It is a
// template over a "sink":
//   EcSink  (write): every syntax element value comes from the record, sink.sym()
//                    codes it with od_ec and returns it unchanged;
//   DecSink (parse): sink.sym() decodes the element (spec 8.2 symbol decoder) and the
//                    walk stores it into a record being built.
// Every walk statement has the form  field = sk.sym(cdf, value_from_record, N),
// so both directions share all context logic.
#include "av1g/av1g.h"
#include "av1g/dsp.h"
#include "av1g/blockinfo.h"
#include "av1g/entenc.h"
#include "av1g/cdfctx.h"
#include "av1g/levels_gen.h"
#include "av1g/symstream.h"
#include "av1g/postfilter.h"
#include "av1g/internal.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <memory>
#include <thread>
#include <vector>

namespace av1g {

static_assert(sizeof(av1g_block) == 16, "av1g_block must be 16 bytes");
static_assert(sizeof(av1g_txb) == 16, "av1g_txb must be 16 bytes");
static_assert(sizeof(((av1g_cdfs *)0)->coeff_base) == sizeof(Default_Coeff_Base_Cdf_host[0]), "cdf dims");
static_assert(sizeof(((av1g_cdfs *)0)->coeff_br) == sizeof(Default_Coeff_Br_Cdf_host[0]), "cdf dims");
static_assert(sizeof(((av1g_cdfs *)0)->y_mode) == sizeof(Default_Intra_Frame_Y_Mode_Cdf_host), "cdf dims");

Error::Error(int c, const char *fmt, ...) : std::runtime_error("av1g"), code(c) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
}

// ---------------------------------------------------------------------------
// tiles / levels
// ---------------------------------------------------------------------------
static int tile_log2(int blk, int target) {
    int k = 0;
    while ((blk << k) < target) k++;
    return k;
}

bool compute_tiles(uint32_t W, uint32_t H, int colsLog2, int rowsLog2, TileInfo &t) {
    const int MiCols = av1g_mi_cols(W), MiRows = av1g_mi_rows(H);
    const int sbCols = (MiCols + 15) >> 4, sbRows = (MiRows + 15) >> 4;
    const int maxTileWidthSb = AV1G_MAX_TILE_WIDTH >> 6;
    const int maxTileAreaSb = AV1G_MAX_TILE_AREA >> 12;
    t.minLog2TileCols = tile_log2(maxTileWidthSb, sbCols);
    t.maxLog2TileCols = tile_log2(1, sbCols < AV1G_MAX_TILE_COLS ? sbCols : AV1G_MAX_TILE_COLS);
    t.maxLog2TileRows = tile_log2(1, sbRows < AV1G_MAX_TILE_ROWS ? sbRows : AV1G_MAX_TILE_ROWS);
    t.minLog2Tiles = tile_log2(maxTileAreaSb, sbRows * sbCols);
    if (t.minLog2Tiles < t.minLog2TileCols) t.minLog2Tiles = t.minLog2TileCols;
    if (colsLog2 < 0) colsLog2 = t.minLog2TileCols;
    if (colsLog2 < t.minLog2TileCols || colsLog2 > t.maxLog2TileCols) return false;
    t.colsLog2 = colsLog2;
    int tileWidthSb = (sbCols + (1 << colsLog2) - 1) >> colsLog2;
    int i = 0;
    for (int s = 0; s < sbCols; s += tileWidthSb) t.miColStarts[i++] = s << 4;
    t.miColStarts[i] = MiCols;
    t.cols = i;
    t.minLog2TileRows = t.minLog2Tiles - colsLog2;
    if (t.minLog2TileRows < 0) t.minLog2TileRows = 0;
    bool autoRows = rowsLog2 < 0;
    if (autoRows) rowsLog2 = t.minLog2TileRows;
    for (;;) {
        if (rowsLog2 < t.minLog2TileRows || rowsLog2 > t.maxLog2TileRows) return false;
        int tileHeightSb = (sbRows + (1 << rowsLog2) - 1) >> rowsLog2;
        if (tileWidthSb * tileHeightSb <= maxTileAreaSb) {
            i = 0;
            for (int s = 0; s < sbRows; s += tileHeightSb) t.miRowStarts[i++] = s << 4;
            t.miRowStarts[i] = MiRows;
            t.rows = i;
            t.rowsLog2 = rowsLog2;
            return true;
        }
        if (!autoRows) return false;  // conformance: tile area too large
        rowsLog2++;
    }
}

static int choose_level(uint32_t W, uint32_t H, int ntiles, int tcols) {
    if (W < 16 || H < 16) return 31;
    for (int i = 0; i < AV1G_NUM_LEVELS; i++) {
        const uint32_t *L = av1g_levels[i];
        if ((uint64_t)W * H <= L[1] && W <= L[2] && H <= L[3] && (uint32_t)ntiles <= L[4] && (uint32_t)tcols <= L[5])
            return (int)L[0];
    }
    return 31;
}

// ---------------------------------------------------------------------------
// sinks
// ---------------------------------------------------------------------------
struct EcSink {
    static constexpr bool kWrite = true;
    av1g_ec ec;
    std::vector<uint16_t> buf;
    uint64_t nsym = 0;
    EcSink() { buf.resize(1 << 16); av1g_ec_init(&ec, buf.data(), (uint32_t)buf.size()); }
    void ensure() {
        if (ec.offs + 16 > ec.cap) {
            buf.resize(buf.size() * 2);
            ec.buf = buf.data();
            ec.cap = (uint32_t)buf.size();
        }
    }
    int sym(uint16_t *cdf, int s, int N) { ensure(); av1g_ec_symbol(&ec, s, cdf, N); nsym++; return s; }
    int bit(int b) { ensure(); av1g_ec_bool(&ec, b); nsym++; return b; }
    int split_or(uint16_t *pc, int vert, int b) {
        uint16_t tmp[3] = {(uint16_t)(32768u - av1g_split_or_psum(pc, vert)), 32768, 0};
        ensure();
        av1g_ec_encode_cdf(&ec, b, tmp, 2);
        nsym++;
        return b;
    }
    std::vector<uint8_t> finish() {
        ensure();
        std::vector<uint8_t> out(ec.offs + 8);
        int n = av1g_ec_done(&ec, out.data());
        if (n < 0) throw Error(AV1G_ERR_INTERNAL, "entropy coder buffer overflow");
        out.resize(n);
        return out;
    }
};

// Symbol decoder exactly as specified in AV1 spec 8.2.2 .. 8.2.6.
struct DecSink {
    static constexpr bool kWrite = false;
    const uint8_t *data;
    size_t size, bitpos = 0;
    uint32_t SymbolValue = 0, SymbolRange = 0;
    int64_t SymbolMaxBits = 0;
    uint64_t nsym = 0;
    uint32_t f(int n) {
        uint32_t x = 0;
        for (int i = 0; i < n; i++, bitpos++) {
            int b = (bitpos >> 3) < size ? (data[bitpos >> 3] >> (7 - (bitpos & 7))) & 1 : 0;
            x = 2 * x + b;
        }
        return x;
    }
    DecSink(const uint8_t *d, size_t sz) : data(d), size(sz) {
        int numBits = sz * 8 < 15 ? (int)(sz * 8) : 15;
        uint32_t buf = f(numBits);
        uint32_t paddedBuf = buf << (15 - numBits);
        SymbolValue = ((1u << 15) - 1) ^ paddedBuf;
        SymbolRange = 1u << 15;
        SymbolMaxBits = 8 * (int64_t)sz - 15;
    }
    int read(uint16_t *cdf, int N, bool adapt) {
        uint32_t cur = SymbolRange, prev;
        int symbol = -1;
        do {
            symbol++;
            prev = cur;
            uint32_t fq = (1u << 15) - cdf[symbol];
            cur = ((SymbolRange >> 8) * (fq >> AV1G_EC_PROB_SHIFT)) >> (7 - AV1G_EC_PROB_SHIFT);
            cur += AV1G_EC_MIN_PROB * (N - symbol - 1);
        } while (SymbolValue < cur);
        SymbolRange = prev - cur;
        SymbolValue -= cur;
        int bits = 15 - (av1g_ilog_nz(SymbolRange) - 1);
        SymbolRange <<= bits;
        int numBits = (int)std::min<int64_t>(bits, std::max<int64_t>(0, SymbolMaxBits));
        uint32_t newData = f(numBits);
        uint32_t paddedData = newData << (bits - numBits);
        SymbolValue = paddedData ^ (((SymbolValue + 1) << bits) - 1);
        SymbolMaxBits -= bits;
        if (adapt) av1g_update_cdf(cdf, symbol, N);
        nsym++;
        return symbol;
    }
    int sym(uint16_t *cdf, int, int N) { return read(cdf, N, true); }
    int bit(int) {
        uint16_t c[3] = {1 << 14, 1 << 15, 0};
        return read(c, 2, false);
    }
    int split_or(uint16_t *pc, int vert, int) {
        uint16_t tmp[3] = {(uint16_t)(32768u - av1g_split_or_psum(pc, vert)), 32768, 0};
        return read(tmp, 2, false);
    }
};

// Write + record the packed symbol stream (M4 reference streams).
struct TeeSink : EcSink {
    const uint16_t *base;
    std::vector<uint32_t> *out;
    TeeSink(const uint16_t *b, std::vector<uint32_t> *o) : base(b), out(o) {}
    int sym(uint16_t *cdf, int s, int N) {
        out->push_back(av1g_sym_pack(AV1G_SYM_ADAPT, (uint32_t)(cdf - base), s, N));
        return EcSink::sym(cdf, s, N);
    }
    int bit(int b) {
        out->push_back(av1g_sym_pack(AV1G_SYM_BOOL, 0, b, 2));
        return EcSink::bit(b);
    }
    int split_or(uint16_t *pc, int vert, int b) {
        out->push_back(av1g_sym_pack(vert ? AV1G_SYM_SPLIT_OR_VERT : AV1G_SYM_SPLIT_OR_HORZ, (uint32_t)(pc - base), b, 2));
        return EcSink::split_or(pc, vert, b);
    }
};

// ---------------------------------------------------------------------------
// the walk
// ---------------------------------------------------------------------------
class Encoder {
public:
    // write mode
    Encoder(av1g_decision_record *rec, const av1g_encode_opts &o, TxbHook *h = nullptr) : R(rec) { opts = o; hook = h; }
    // parse mode
    explicit Encoder(ParseStore *ps) : R(&ps->rec), PS(ps) { doRecon = false; opts.flags = AV1G_ENC_SKIP_RECON; opts.seq_level_idx = -1; }
    void run(av1g_output *out);
    void parse(const uint8_t *obus, size_t n);
    std::vector<std::vector<uint32_t>> *tileSyms = nullptr;  // if set, record per-tile symbol streams
    const std::vector<TileSkip> *skipTiles = nullptr;         // Glass Act: tiles not to walk
    std::vector<std::vector<uint8_t>> *tilePayloadsOut = nullptr;  // Glass Act: if set, every tile's payload

private:
    av1g_decision_record *R;
    ParseStore *PS = nullptr;
    bool doRecon = true, fixRange = false;
    av1g_encode_opts opts = {0, -1};
    TxbHook *hook = nullptr;
    const av1g_frame_params *fp = nullptr;
    int W = 0, H = 0, MiCols = 0, MiRows = 0, mono = 0, sbCols = 0, sbRows = 0;
    TileInfo tiles;
    int dcQ[3], acQ[3];
    int qmLevel[3] = {15, 15, 15};  // 15 = no matrix
    int CurrentQIndex = 0, readDeltas = 0, blockQ = -1;
    void set_block_q(int qidx) {
        if (qidx == blockQ) return;
        blockQ = qidx;
        dcQ[0] = av1g_dc_q(qidx + fp->delta_q_y_dc); acQ[0] = av1g_ac_q(qidx);
        dcQ[1] = av1g_dc_q(qidx + fp->delta_q_u_dc); acQ[1] = av1g_ac_q(qidx + fp->delta_q_u_ac);
        dcQ[2] = av1g_dc_q(qidx + fp->delta_q_v_dc); acQ[2] = av1g_ac_q(qidx + fp->delta_q_v_ac);
    }
    template <class S> int lit(S &sk, int vW, int n) {  // L(n) literal, MSB first
        int v = 0;
        for (int i = n - 1; i >= 0; i--) v = (v << 1) | sk.bit((vW >> i) & 1);
        return v;
    }
    // Glass Act: the frame's buffers live in one shared struct, so that a copy of this
    // encoder codes one tile on its own thread (tiles write disjoint parts of them) while
    // its tile state (contexts, CDFs, cursor, current block) is its own.
    struct FrameBufs {
        std::vector<uint8_t> plane[3];
        std::vector<uint8_t> mapMiSize, mapYMode, mapSkip, mapTxSize, mapUVMode;
        std::vector<uint8_t> lfTxUV[2];
        std::vector<int8_t> sbCdef;
        std::vector<uint32_t> ordMap[3];
    };
    std::shared_ptr<FrameBufs> frameBufs = std::make_shared<FrameBufs>();
    // recon planes (cover all superblocks)
    int pstride[3] = {0, 0, 0}, pheight[3] = {0, 0, 0};
    std::vector<uint8_t> (&plane)[3] = frameBufs->plane;
    // 4x4-granular mode info maps
    std::vector<uint8_t> &mapMiSize = frameBufs->mapMiSize, &mapYMode = frameBufs->mapYMode, &mapSkip = frameBufs->mapSkip,
                         &mapTxSize = frameBufs->mapTxSize, &mapUVMode = frameBufs->mapUVMode;
    std::vector<uint8_t> (&lfTxUV)[2] = frameBufs->lfTxUV;  // LoopfilterTxSizes for U, V (chroma 4x4 units)
    std::vector<int8_t> &sbCdef = frameBufs->sbCdef;        // cdef_idx per 64x64 SB (-1: no non-skip block)
    int sbIndex = 0;                  // current SB (raster)
    void postfilter();
    // coefficient contexts
    std::vector<uint8_t> aboveLevel[3], aboveDc[3], leftLevel[3], leftDc[3];
    // AV1G_ENC_CHECK_EDGES: per-plane map of the covering tx block index
    std::vector<uint32_t> (&ordMap)[3] = frameBufs->ordMap;
    uint32_t curTxb = 0;
    // tile bounds
    int miRowStart = 0, miRowEnd = 0, miColStart = 0, miColEnd = 0;
    uint8_t blockDecoded[3][18][18];
    av1g_cdfs cdf;
    uint32_t cursor = 0, tileEnd = 0;
    uint64_t nFixed = 0;
    // current block
    av1g_block *B = nullptr;
    uint32_t bIdx = 0;
    int MiRow = 0, MiCol = 0, MiSize = 0, bw4 = 0, bh4 = 0, hasChroma = 0;
    int availU = 0, availL = 0, availUC = 0, availLC = 0, txSize = 0;
    int maxLumaW = 0, maxLumaH = 0;

    uint8_t *plane_ptr(int p) { return plane[p].data(); }
    bool is_inside(int r, int c) const {
        return c >= miColStart && c < miColEnd && r >= miRowStart && r < miRowEnd;
    }
    uint8_t &mapAt(std::vector<uint8_t> &m, int r, int c) { return m[(size_t)r * MiCols + c]; }
    int16_t *coeff_ptr(const av1g_txb &t) { return PS ? PS->coeffs.data() + t.coeff_off : R->coeffs + t.coeff_off; }

    void setup_frame();
    template <class S> void encode_tile(S &sk, int tileRow, int tileCol);
    template <class S> void encode_partition(S &sk, int r, int c, int bSize);
    template <class S> void encode_block(S &sk, int r, int c, int bsize);
    template <class S> void code_txb(S &sk, av1g_txb &t, int xi, int yi);
    template <class S> int code_coeffs(S &sk, int plane, int txSz, int &txType, int x4, int y4, int16_t *q, int eob);
    int derive_partition(int r, int c, int bSize, int hasRows, int hasCols);
    void clear_block_decoded(int r, int c);
    void check_block_fields(const av1g_block &b);
    void write_headers(BitWriter &seq, BitWriter &fh, int level);
};

void Encoder::check_block_fields(const av1g_block &b) {
    const int bs = b.bsize;
    if (bs >= AV1G_BLOCK_SIZES || bs == AV1G_BLOCK_64X128 || bs == AV1G_BLOCK_128X64 || bs == AV1G_BLOCK_128X128)
        throw Error(AV1G_ERR_INVALID, "block %u: invalid bsize %d", bIdx, bs);
    if (b.skip > 1) throw Error(AV1G_ERR_INVALID, "block %u: skip must be 0/1", bIdx);
    if (b.y_mode > AV1G_PAETH_PRED) throw Error(AV1G_ERR_INVALID, "block %u: y_mode %d", bIdx, b.y_mode);
    int dirOk = bs >= AV1G_BLOCK_8X8;
    if (b.angle_delta_y < -3 || b.angle_delta_y > 3 ||
        (b.angle_delta_y && !(dirOk && av1g_is_directional(b.y_mode))))
        throw Error(AV1G_ERR_INVALID, "block %u: angle_delta_y %d not allowed", bIdx, b.angle_delta_y);
    if (fp->tx_mode_select) {
        if (b.tx_depth > av1g_max_tx_depth(bs) || (bs == AV1G_BLOCK_4X4 && b.tx_depth))
            throw Error(AV1G_ERR_INVALID, "block %u: tx_depth %d too large", bIdx, b.tx_depth);
    } else if (b.tx_depth) throw Error(AV1G_ERR_INVALID, "block %u: tx_depth must be 0 (TX_MODE_LARGEST)", bIdx);
    if (fp->enable_cdef ? (b.cdef_idx < 0 || b.cdef_idx >= (1 << fp->cdef_bits)) : b.cdef_idx != 0)
        throw Error(AV1G_ERR_INVALID, "block %u: cdef_idx %d out of range", bIdx, b.cdef_idx);
    if (b.filter_intra && (b.filter_intra > 5 || !fp->enable_filter_intra || b.y_mode != AV1G_DC_PRED ||
                           av1g_bw4(bs) > 8 || av1g_bh4(bs) > 8))
        throw Error(AV1G_ERR_INVALID, "block %u: filter_intra %d not allowed here", bIdx, b.filter_intra);
    if (!fp->delta_q_present && b.sb_qindex && b.sb_qindex != fp->base_q_idx)
        throw Error(AV1G_ERR_INVALID, "block %u: sb_qindex set but delta_q_present = 0", bIdx);
    if (hasChroma) {
        if (b.uv_mode > AV1G_UV_CFL_PRED) throw Error(AV1G_ERR_INVALID, "block %u: uv_mode %d", bIdx, b.uv_mode);
        if (b.uv_mode == AV1G_UV_CFL_PRED) {
            if (!av1g_cfl_allowed(bs)) throw Error(AV1G_ERR_INVALID, "block %u: CFL not allowed for bsize %d", bIdx, bs);
            if (b.cfl_alpha_u < -16 || b.cfl_alpha_u > 16 || b.cfl_alpha_v < -16 || b.cfl_alpha_v > 16 ||
                (b.cfl_alpha_u == 0 && b.cfl_alpha_v == 0))
                throw Error(AV1G_ERR_INVALID, "block %u: bad CFL alphas %d %d", bIdx, b.cfl_alpha_u, b.cfl_alpha_v);
        }
        if (b.angle_delta_uv < -3 || b.angle_delta_uv > 3 ||
            (b.angle_delta_uv && !(dirOk && av1g_is_directional(b.uv_mode))))
            throw Error(AV1G_ERR_INVALID, "block %u: angle_delta_uv %d not allowed", bIdx, b.angle_delta_uv);
    }
}

void Encoder::clear_block_decoded(int r, int c) {
    for (int p = 0; p < (mono ? 1 : 3); p++) {
        const int sub = p ? 1 : 0;
        const int sbWidth4 = (miColEnd - c) >> sub, sbHeight4 = (miRowEnd - r) >> sub;
        for (int y = -1; y <= (16 >> sub); y++)
            for (int x = -1; x <= (16 >> sub); x++) {
                uint8_t v;
                if (y < 0 && x < sbWidth4) v = 1;
                else if (x < 0 && y < sbHeight4) v = 1;
                else v = 0;
                blockDecoded[p][y + 1][x + 1] = v;
            }
        blockDecoded[p][(16 >> sub) + 1][0] = 0;
    }
}

// Derive the partition type of node (r, c, bSize) from the block sequence (write mode).
int Encoder::derive_partition(int r, int c, int bSize, int hasRows, int hasCols) {
    if (cursor >= tileEnd) throw Error(AV1G_ERR_INVALID, "block list ends inside tile (expected block at mi %d,%d)", r, c);
    const av1g_block &b = R->blocks[cursor];
    if (b.mi_row != r || b.mi_col != c)
        throw Error(AV1G_ERR_INVALID, "block %u at mi (%d,%d), expected a block starting at (%d,%d)", cursor,
                    b.mi_row, b.mi_col, r, c);
    const int half = av1g_bw4(bSize) >> 1;
    const int hz = AV1G_T(Partition_Subsize)[AV1G_PARTITION_HORZ][bSize];
    const int vt = AV1G_T(Partition_Subsize)[AV1G_PARTITION_VERT][bSize];
    const int sp = AV1G_T(Partition_Subsize)[AV1G_PARTITION_SPLIT][bSize];
    const int h4 = AV1G_T(Partition_Subsize)[AV1G_PARTITION_HORZ_4][bSize];
    const int v4 = AV1G_T(Partition_Subsize)[AV1G_PARTITION_VERT_4][bSize];
    auto nxt = [&](uint32_t k) -> const av1g_block * { return cursor + k < tileEnd ? &R->blocks[cursor + k] : nullptr; };
    auto at = [&](const av1g_block *n, int rr, int cc, int bs) { return n && n->mi_row == rr && n->mi_col == cc && n->bsize == bs; };
    int p;
    const int bs = b.bsize;
    if (bs == bSize) p = AV1G_PARTITION_NONE;
    else if (bs == hz) p = at(nxt(1), r + half, c, sp) ? AV1G_PARTITION_HORZ_B : AV1G_PARTITION_HORZ;
    else if (bs == vt) p = at(nxt(1), r, c + half, sp) ? AV1G_PARTITION_VERT_B : AV1G_PARTITION_VERT;
    else if (bs == sp && bSize > AV1G_BLOCK_8X8 && hasRows && hasCols && at(nxt(1), r + half, c, sp))
        p = AV1G_PARTITION_VERT_A;
    else if (bs == sp && bSize > AV1G_BLOCK_8X8 && hasRows && hasCols && at(nxt(1), r, c + half, sp) &&
             at(nxt(2), r + half, c, hz))
        p = AV1G_PARTITION_HORZ_A;
    else if (bSize > AV1G_BLOCK_8X8 && bs == h4) p = AV1G_PARTITION_HORZ_4;
    else if (bSize > AV1G_BLOCK_8X8 && bs == v4) p = AV1G_PARTITION_VERT_4;
    else p = AV1G_PARTITION_SPLIT;
    bool ok;
    if (bSize == AV1G_BLOCK_8X8 && p > AV1G_PARTITION_SPLIT) ok = false;
    else if (hasRows && hasCols) ok = true;
    else if (hasCols) ok = (p == AV1G_PARTITION_HORZ || p == AV1G_PARTITION_SPLIT);
    else if (hasRows) ok = (p == AV1G_PARTITION_VERT || p == AV1G_PARTITION_SPLIT);
    else ok = (p == AV1G_PARTITION_SPLIT);
    if (!ok)
        throw Error(AV1G_ERR_INVALID, "block %u: implied partition %d of %dx%d node at mi (%d,%d) not allowed here",
                    cursor, p, 4 * av1g_bw4(bSize), 4 * av1g_bh4(bSize), r, c);
    return p;
}

template <class S>
void Encoder::encode_partition(S &sk, int r, int c, int bSize) {
    if (r >= MiRows || c >= MiCols) return;
    const int aU = is_inside(r - 1, c), aL = is_inside(r, c - 1);
    const int num4x4 = av1g_bw4(bSize), half = num4x4 >> 1, quarter = half >> 1;
    const int hasRows = (r + half) < MiRows, hasCols = (c + half) < MiCols;
    int p;
    if (bSize < AV1G_BLOCK_8X8) {
        p = AV1G_PARTITION_NONE;
    } else {
        p = S::kWrite ? derive_partition(r, c, bSize, hasRows, hasCols) : 0;
        const int bsl = AV1G_T(Mi_Width_Log2)[bSize];
        const int above = aU && AV1G_T(Mi_Width_Log2)[mapAt(mapMiSize, r - 1, c)] < bsl;
        const int left = aL && AV1G_T(Mi_Height_Log2)[mapAt(mapMiSize, r, c - 1)] < bsl;
        const int ctx = left * 2 + above;
        uint16_t *pc = bsl == 1 ? cdf.partition_w8[ctx] : bsl == 2 ? cdf.partition_w16[ctx]
                     : bsl == 3 ? cdf.partition_w32[ctx] : cdf.partition_w64[ctx];
        if (hasRows && hasCols) {
            p = sk.sym(pc, p, bsl == 1 ? 4 : 10);
        } else if (hasCols) {  // split_or_horz
            p = sk.split_or(pc, 0, p == AV1G_PARTITION_SPLIT) ? AV1G_PARTITION_SPLIT : AV1G_PARTITION_HORZ;
        } else if (hasRows) {  // split_or_vert
            p = sk.split_or(pc, 1, p == AV1G_PARTITION_SPLIT) ? AV1G_PARTITION_SPLIT : AV1G_PARTITION_VERT;
        } else {
            p = AV1G_PARTITION_SPLIT;
        }
    }
    const int subSize = AV1G_T(Partition_Subsize)[p][bSize];
    const int splitSize = AV1G_T(Partition_Subsize)[AV1G_PARTITION_SPLIT][bSize];
    switch (p) {
    case AV1G_PARTITION_NONE: encode_block(sk, r, c, subSize); break;
    case AV1G_PARTITION_HORZ:
        encode_block(sk, r, c, subSize);
        if (hasRows) encode_block(sk, r + half, c, subSize);
        break;
    case AV1G_PARTITION_VERT:
        encode_block(sk, r, c, subSize);
        if (hasCols) encode_block(sk, r, c + half, subSize);
        break;
    case AV1G_PARTITION_SPLIT:
        encode_partition(sk, r, c, subSize);
        encode_partition(sk, r, c + half, subSize);
        encode_partition(sk, r + half, c, subSize);
        encode_partition(sk, r + half, c + half, subSize);
        break;
    case AV1G_PARTITION_HORZ_A:
        encode_block(sk, r, c, splitSize);
        encode_block(sk, r, c + half, splitSize);
        encode_block(sk, r + half, c, subSize);
        break;
    case AV1G_PARTITION_HORZ_B:
        encode_block(sk, r, c, subSize);
        encode_block(sk, r + half, c, splitSize);
        encode_block(sk, r + half, c + half, splitSize);
        break;
    case AV1G_PARTITION_VERT_A:
        encode_block(sk, r, c, splitSize);
        encode_block(sk, r + half, c, splitSize);
        encode_block(sk, r, c + half, subSize);
        break;
    case AV1G_PARTITION_VERT_B:
        encode_block(sk, r, c, subSize);
        encode_block(sk, r, c + half, splitSize);
        encode_block(sk, r + half, c + half, splitSize);
        break;
    case AV1G_PARTITION_HORZ_4:
        for (int i = 0; i < 4; i++)
            if (i < 3 || r + quarter * 3 < MiRows) encode_block(sk, r + quarter * i, c, subSize);
        break;
    default:  // VERT_4
        for (int i = 0; i < 4; i++)
            if (i < 3 || c + quarter * 3 < MiCols) encode_block(sk, r, c + quarter * i, subSize);
        break;
    }
}

template <class S>
void Encoder::encode_block(S &sk, int r, int c, int bsize) {
    if (S::kWrite) {
        if (cursor >= tileEnd) throw Error(AV1G_ERR_INVALID, "block list ends early (expected block at mi %d,%d)", r, c);
        bIdx = cursor;
        B = &R->blocks[cursor];
        if (B->mi_row != r || B->mi_col != c || B->bsize != bsize)
            throw Error(AV1G_ERR_INVALID, "block %u: got mi (%d,%d) bsize %d, partition syntax expects (%d,%d) bsize %d",
                        cursor, B->mi_row, B->mi_col, B->bsize, r, c, bsize);
        cursor++;
    } else {
        av1g_block nb;
        memset(&nb, 0, sizeof nb);
        nb.mi_row = (uint16_t)r;
        nb.mi_col = (uint16_t)c;
        nb.bsize = (uint8_t)bsize;
        PS->blocks.push_back(nb);
        PS->block_txb.push_back((uint32_t)PS->txb.size());
        bIdx = (uint32_t)PS->blocks.size() - 1;
        B = &PS->blocks.back();
    }
    av1g_block &b = *B;
    MiRow = r; MiCol = c; MiSize = bsize;
    bw4 = av1g_bw4(bsize); bh4 = av1g_bh4(bsize);
    hasChroma = av1g_has_chroma(bsize, r, c, mono);
    availU = is_inside(r - 1, c);
    availL = is_inside(r, c - 1);
    availUC = availU; availLC = availL;
    if (hasChroma) {
        if (bh4 == 1) availUC = is_inside(r - 2, c);
        if (bw4 == 1) availLC = is_inside(r, c - 2);
    } else {
        availUC = availLC = 0;
    }
    if (S::kWrite) check_block_fields(b);

    // ---- intra_frame_mode_info ----
    {
        int ctx = (availU ? mapAt(mapSkip, r - 1, c) : 0) + (availL ? mapAt(mapSkip, r, c - 1) : 0);
        b.skip = (uint8_t)sk.sym(cdf.skip[ctx], b.skip, 2);
    }
    // ---- read_cdef ----
    if (fp->enable_cdef && !b.skip) {
        if (sbCdef[sbIndex] == -1) {
            b.cdef_idx = (int8_t)lit(sk, b.cdef_idx, fp->cdef_bits);
            sbCdef[sbIndex] = b.cdef_idx;
        } else if (S::kWrite) {
            if (b.cdef_idx != sbCdef[sbIndex])
                throw Error(AV1G_ERR_INVALID, "block %u: cdef_idx %d differs from its superblock's %d", bIdx, b.cdef_idx, sbCdef[sbIndex]);
        } else {
            b.cdef_idx = sbCdef[sbIndex];
        }
    }
    // ---- read_delta_qindex ----
    if (fp->delta_q_present) {
        if (readDeltas && !(bsize == AV1G_BLOCK_64X64 && b.skip)) {
            const int res = fp->delta_q_res, step = 1 << res;
            int reducedW = 0;
            if (S::kWrite) {
                const int diff = (int)b.sb_qindex - CurrentQIndex;
                if (b.sb_qindex < 1 || diff % step)
                    throw Error(AV1G_ERR_INVALID, "block %u: sb_qindex %d not reachable from %d with delta_q_res %d (use av1g_legalize_sb_qindex)",
                                bIdx, b.sb_qindex, CurrentQIndex, res);
                reducedW = diff / step;
            }
            const int absW = reducedW < 0 ? -reducedW : reducedW;
            int a = sk.sym(cdf.delta_q, absW < AV1G_DELTA_Q_SMALL ? absW : AV1G_DELTA_Q_SMALL, AV1G_DELTA_Q_SMALL + 1);
            if (a == AV1G_DELTA_Q_SMALL) {
                int remW = 1;
                while (((absW - 1) >> (remW + 1)) > 0) remW++;  // floor(log2(abs - 1))
                const int remBits = lit(sk, remW - 1, 3) + 1;
                const int absBits = lit(sk, (absW - 1) - (1 << remBits), remBits);
                a = absBits + (1 << remBits) + 1;
            }
            if (a) {
                const int sign = sk.bit(reducedW < 0);
                const int reduced = sign ? -a : a;
                CurrentQIndex = av1g_clip3(1, 255, CurrentQIndex + reduced * step);
            }
        }
        if (S::kWrite) {
            if (b.sb_qindex != CurrentQIndex && !(bsize == AV1G_BLOCK_64X64 && b.skip))
                throw Error(AV1G_ERR_INVALID, "block %u: sb_qindex %d differs from its superblock's qindex %d", bIdx, b.sb_qindex,
                            CurrentQIndex);
        } else {
            b.sb_qindex = (uint8_t)CurrentQIndex;
        }
    }
    readDeltas = 0;
    set_block_q(fp->delta_q_present ? CurrentQIndex : fp->base_q_idx);
    {
        int am = AV1G_T(Intra_Mode_Context)[availU ? mapAt(mapYMode, r - 1, c) : AV1G_DC_PRED];
        int lm = AV1G_T(Intra_Mode_Context)[availL ? mapAt(mapYMode, r, c - 1) : AV1G_DC_PRED];
        b.y_mode = (uint8_t)sk.sym(cdf.y_mode[am][lm], b.y_mode, AV1G_INTRA_MODES);
    }
    if (bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(b.y_mode))
        b.angle_delta_y = (int8_t)(sk.sym(cdf.angle_delta[b.y_mode - AV1G_V_PRED], b.angle_delta_y + AV1G_MAX_ANGLE_DELTA, 7) -
                                   AV1G_MAX_ANGLE_DELTA);
    if (hasChroma) {
        if (av1g_cfl_allowed(bsize))
            b.uv_mode = (uint8_t)sk.sym(cdf.uv_mode_cfl_allowed[b.y_mode], b.uv_mode, AV1G_UV_INTRA_MODES_CFL_ALLOWED);
        else
            b.uv_mode = (uint8_t)sk.sym(cdf.uv_mode_cfl_not_allowed[b.y_mode], b.uv_mode, AV1G_UV_INTRA_MODES_CFL_NOT_ALLOWED);
        if (b.uv_mode == AV1G_UV_CFL_PRED) {
            const int wU = b.cfl_alpha_u == 0 ? AV1G_CFL_SIGN_ZERO : b.cfl_alpha_u < 0 ? AV1G_CFL_SIGN_NEG : AV1G_CFL_SIGN_POS;
            const int wV = b.cfl_alpha_v == 0 ? AV1G_CFL_SIGN_ZERO : b.cfl_alpha_v < 0 ? AV1G_CFL_SIGN_NEG : AV1G_CFL_SIGN_POS;
            const int js = sk.sym(cdf.cfl_sign, wU * 3 + wV - 1, AV1G_CFL_JOINT_SIGNS);
            const int signU = (js + 1) / 3, signV = (js + 1) % 3;
            if (signU != AV1G_CFL_SIGN_ZERO) {
                int a = sk.sym(cdf.cfl_alpha[(signU - 1) * 3 + signV], (b.cfl_alpha_u < 0 ? -b.cfl_alpha_u : b.cfl_alpha_u) - 1,
                               AV1G_CFL_ALPHABET_SIZE) + 1;
                b.cfl_alpha_u = (int8_t)(signU == AV1G_CFL_SIGN_NEG ? -a : a);
            } else b.cfl_alpha_u = 0;
            if (signV != AV1G_CFL_SIGN_ZERO) {
                int a = sk.sym(cdf.cfl_alpha[(signV - 1) * 3 + signU], (b.cfl_alpha_v < 0 ? -b.cfl_alpha_v : b.cfl_alpha_v) - 1,
                               AV1G_CFL_ALPHABET_SIZE) + 1;
                b.cfl_alpha_v = (int8_t)(signV == AV1G_CFL_SIGN_NEG ? -a : a);
            } else b.cfl_alpha_v = 0;
        }
        if (bsize >= AV1G_BLOCK_8X8 && av1g_is_directional(b.uv_mode))
            b.angle_delta_uv = (int8_t)(sk.sym(cdf.angle_delta[b.uv_mode - AV1G_V_PRED], b.angle_delta_uv + AV1G_MAX_ANGLE_DELTA, 7) -
                                        AV1G_MAX_ANGLE_DELTA);
    }
    // palette_mode_info(): only present with allow_screen_content_tools; palette is never used
    if (fp->allow_screen_content_tools && bsize >= AV1G_BLOCK_8X8 && bw4 <= 16 && bh4 <= 16) {
        const int bsizeCtx = AV1G_T(Mi_Width_Log2)[bsize] + AV1G_T(Mi_Height_Log2)[bsize] - 2;
        if (b.y_mode == AV1G_DC_PRED && sk.sym(cdf.palette_y_mode[bsizeCtx][0], 0, 2))
            throw Error(AV1G_ERR_INVALID, "block %u: palette (has_palette_y) not supported", bIdx);
        if (hasChroma && b.uv_mode == AV1G_DC_PRED && sk.sym(cdf.palette_uv_mode[0], 0, 2))
            throw Error(AV1G_ERR_INVALID, "block %u: palette (has_palette_uv) not supported", bIdx);
    }
    // filter_intra_mode_info()
    if (fp->enable_filter_intra && b.y_mode == AV1G_DC_PRED && bw4 <= 8 && bh4 <= 8) {
        if (sk.sym(cdf.filter_intra[bsize], b.filter_intra != 0, 2))
            b.filter_intra = (uint8_t)(sk.sym(cdf.filter_intra_mode, b.filter_intra - 1, 5) + 1);
        else
            b.filter_intra = 0;
    } else if (!S::kWrite) {
        b.filter_intra = 0;
    }

    // ---- read_block_tx_size / read_tx_size(allowSelect = 1) ----
    if (fp->tx_mode_select && bsize > AV1G_BLOCK_4X4) {
        const int maxRect = AV1G_T(Max_Tx_Size_Rect)[bsize];
        const int maxTxDepth = AV1G_T(Max_Tx_Depth)[bsize];
        const int aboveW = availU ? AV1G_T(Tx_Width)[mapAt(mapTxSize, r - 1, c)] : 0;
        const int leftH = availL ? AV1G_T(Tx_Height)[mapAt(mapTxSize, r, c - 1)] : 0;
        const int ctx = (aboveW >= AV1G_T(Tx_Width)[maxRect]) + (leftH >= AV1G_T(Tx_Height)[maxRect]);
        if (maxTxDepth == 4) b.tx_depth = (uint8_t)sk.sym(cdf.tx_64x64[ctx], b.tx_depth, 3);
        else if (maxTxDepth == 3) b.tx_depth = (uint8_t)sk.sym(cdf.tx_32x32[ctx], b.tx_depth, 3);
        else if (maxTxDepth == 2) b.tx_depth = (uint8_t)sk.sym(cdf.tx_16x16[ctx], b.tx_depth, 3);
        else b.tx_depth = (uint8_t)sk.sym(cdf.tx_8x8[ctx], b.tx_depth, 2);
    }
    txSize = av1g_luma_tx_size(bsize, b.tx_depth);
    if (!S::kWrite) check_block_fields(b);

    if (b.skip) {  // reset_block_context
        for (int p = 0; p < 1 + 2 * hasChroma; p++) {
            const int sub = p ? 1 : 0;
            for (int i = MiCol >> sub; i < ((MiCol + bw4) >> sub); i++) aboveLevel[p][i] = aboveDc[p][i] = 0;
            for (int i = MiRow >> sub; i < ((MiRow + bh4) >> sub); i++) leftLevel[p][i] = leftDc[p][i] = 0;
        }
    }
    const int rEnd = r + bh4 < MiRows ? r + bh4 : MiRows, cEnd = c + bw4 < MiCols ? c + bw4 : MiCols;
    for (int y = r; y < rEnd; y++)
        for (int x = c; x < cEnd; x++) {
            mapAt(mapYMode, y, x) = b.y_mode;
            if (hasChroma) mapAt(mapUVMode, y, x) = b.uv_mode;
        }

    // ---- residual: tx blocks in bitstream order ----
    if (S::kWrite) {
        const uint32_t t0 = R->block_txb[bIdx], t1 = R->block_txb[bIdx + 1];
        uint32_t ti = t0;
        av1g_for_each_txb(bsize, r, c, b.tx_depth, mono, MiRows, MiCols,
                          [&](int plane, int txSz, int x4, int y4, int xi, int yi) {
                              if (ti >= t1 || R->txb[ti].plane != plane || R->txb[ti].tx_size != txSz ||
                                  R->txb[ti].x4 != x4 || R->txb[ti].y4 != y4)
                                  throw Error(AV1G_ERR_INVALID, "block %u: tx layout mismatch (call av1g_layout)", bIdx);
                              curTxb = ti;
                              code_txb(sk, R->txb[ti], xi, yi);
                              ti++;
                          });
        if (ti != t1) throw Error(AV1G_ERR_INVALID, "block %u: tx layout mismatch (count)", bIdx);
    } else {
        av1g_for_each_txb(bsize, r, c, b.tx_depth, mono, MiRows, MiCols,
                          [&](int plane, int txSz, int x4, int y4, int xi, int yi) {
                              av1g_txb t;
                              memset(&t, 0, sizeof t);
                              t.coeff_off = (uint32_t)PS->coeffs.size();
                              t.x4 = (uint16_t)x4;
                              t.y4 = (uint16_t)y4;
                              t.plane = (uint8_t)plane;
                              t.tx_size = (uint8_t)txSz;
                              PS->coeffs.resize(PS->coeffs.size() + av1g_tx_coeffs(txSz), 0);
                              PS->txb.push_back(t);
                              code_txb(sk, PS->txb.back(), xi, yi);
                          });
    }

    for (int y = r; y < rEnd; y++)
        for (int x = c; x < cEnd; x++) {
            mapAt(mapSkip, y, x) = b.skip;
            mapAt(mapTxSize, y, x) = (uint8_t)txSize;
            mapAt(mapMiSize, y, x) = (uint8_t)bsize;
        }
}

template <class S>
void Encoder::code_txb(S &sk, av1g_txb &t, int xi, int yi) {
    const av1g_block &b = *B;
    const int plane = t.plane, txSz = t.tx_size, sub = plane ? 1 : 0;
    const int startX = t.x4 * 4, startY = t.y4 * 4;
    const int row = (startY << sub) >> 2, col = (startX << sub) >> 2;
    const int sbr = row & 15, sbc = col & 15;
    const int stepX = AV1G_T(Tx_Width)[txSz] >> 2, stepY = AV1G_T(Tx_Height)[txSz] >> 2;
    const int log2W = AV1G_T(Tx_Width_Log2)[txSz], log2H = AV1G_T(Tx_Height_Log2)[txSz];
    const int isCfl = plane > 0 && b.uv_mode == AV1G_UV_CFL_PRED;

    if (doRecon) {
        const int mode = plane == 0 ? b.y_mode : (isCfl ? AV1G_DC_PRED : b.uv_mode);
        const int haveLeft = (plane == 0 ? availL : availLC) || xi > 0;
        const int haveAbove = (plane == 0 ? availU : availUC) || yi > 0;
        const int haveAboveRight = blockDecoded[plane][(sbr >> sub) - 1 + 1][(sbc >> sub) + stepX + 1];
        const int haveBelowLeft = blockDecoded[plane][(sbr >> sub) + stepY + 1][(sbc >> sub) - 1 + 1];
        if (opts.flags & AV1G_ENC_CHECK_EDGES) {
            int hl, ha, har, hbl;
            av1g_txb_edges(plane, t.x4, t.y4, txSz, curTxb, xi, yi, plane == 0 ? availL : availLC,
                           plane == 0 ? availU : availUC, miRowEnd, miColEnd, ordMap[plane].data(), (sbCols * 16) >> sub, &hl,
                           &ha, &har, &hbl);
            if (hl != haveLeft || ha != haveAbove || har != haveAboveRight || hbl != haveBelowLeft)
                throw Error(AV1G_ERR_INTERNAL, "block %u plane %d tx (%d,%d): av1g_txb_edges %d%d%d%d != spec %d%d%d%d", bIdx,
                            plane, t.x4, t.y4, hl, ha, har, hbl, haveLeft, haveAbove, haveAboveRight, haveBelowLeft);
        }
        const int maxX = ((MiCols * 4) >> sub) - 1, maxY = ((MiRows * 4) >> sub) - 1;
        uint8_t edgeA[AV1G_EDGE_LEN], edgeL[AV1G_EDGE_LEN];
        uint8_t *A = edgeA + AV1G_EDGE_OFF, *L = edgeL + AV1G_EDGE_OFF;
        uint8_t *pl = plane_ptr(plane);
        av1g_build_edges(pl, pstride[plane], startX, startY, log2W, log2H, haveLeft, haveAbove, haveAboveRight,
                         haveBelowLeft, maxX, maxY, A, L);
        const int filterType = (fp->enable_intra_edge_filter && av1g_is_directional(mode))
                                   ? av1g_get_filter_type(plane, MiRow, MiCol, plane == 0 ? availU : availUC,
                                                          plane == 0 ? availL : availLC, mapYMode.data(), mapUVMode.data(), MiCols)
                                   : 0;
        av1g_predict_intra_ex(mode, plane == 0 ? b.angle_delta_y : b.angle_delta_uv,
                              (plane == 0 && b.filter_intra) ? b.filter_intra - 1 : -1, fp->enable_intra_edge_filter,
                              filterType, haveLeft, haveAbove, log2W, log2H, startX, startY, maxX, maxY, A, L,
                              pl + (size_t)startY * pstride[plane] + startX, pstride[plane]);
        if (isCfl)
            av1g_cfl_predict(pl, pstride[plane], plane_ptr(0), pstride[0], startX, startY, txSz, 1, 1, maxLumaW,
                             maxLumaH, plane == 1 ? b.cfl_alpha_u : b.cfl_alpha_v);
    }
    if (plane == 0) {
        maxLumaW = startX + stepX * 4;
        maxLumaH = startY + stepY * 4;
    }
    t.eob = 0;
    int txType;
    if (plane == 0) {
        txType = t.tx_type;
    } else {
        txType = av1g_chroma_tx_type(txSz, b.uv_mode, fp->reduced_tx_set);
        t.tx_type = (uint8_t)txType;
    }
    if (!b.skip) {
        int16_t *q = coeff_ptr(t);
        const int n = av1g_tx_coeffs(txSz);
        int eob = 0;
        static thread_local int32_t dq[1024], res[4096];
        if (S::kWrite) {
            if (hook && doRecon) {
                hook->on_txb(b, bIdx, t, q, plane_ptr(plane) + (size_t)startY * pstride[plane] + startX, pstride[plane],
                             dcQ[plane], acQ[plane], txType, fp->using_qmatrix ? qmLevel[plane] : 15);
                if (plane == 0) txType = t.tx_type;
            }
            int nz = 0;
            for (int i = 0; i < n; i++) nz |= q[i];
            if (nz && plane == 0) {
                const int set = av1g_get_tx_set_intra(txSz, fp->reduced_tx_set);
                if (txType >= AV1G_TX_TYPES || !av1g_tx_type_in_set_intra(set, txType))
                    throw Error(AV1G_ERR_INVALID, "block %u: luma tx_type %d not in tx set %d of tx size %d", bIdx,
                                txType, set, txSz);
            }
            if (nz && doRecon) {
                for (;;) {
                    av1g_dequant(q, dq, txSz, dcQ[plane], acQ[plane], av1g_qm(fp->using_qmatrix, qmLevel[plane], plane, txSz, txType));
                    uint32_t err = 0;
                    av1g_inv_txfm2d(dq, txSz, txType, res, &err);
                    if (!err) break;
                    if (!fixRange)
                        throw Error(AV1G_ERR_RANGE, "block %u plane %d tx (%d,%d): coefficients overflow inverse transform range (flags %u)",
                                    bIdx, plane, t.x4, t.y4, err);
                    nz = 0;
                    for (int i = 0; i < n; i++) { q[i] = (int16_t)(q[i] / 2); nz |= q[i]; }
                    nFixed++;
                    if (!nz) break;
                }
            }
            if (nz) {
                const uint16_t *scan = av1g_get_scan(txSz, txType);
                for (int c = n - 1; c >= 0; c--)
                    if (q[scan[c]]) { eob = c + 1; break; }
            }
        }
        eob = code_coeffs(sk, plane, txSz, txType, t.x4, t.y4, q, eob);
        if (plane == 0) t.tx_type = (uint8_t)txType;
        t.eob = (uint16_t)eob;
        if (eob > 0 && doRecon)
            av1g_add_residual(plane_ptr(plane) + (size_t)startY * pstride[plane] + startX, pstride[plane], res, txSz, txType);
    }
    for (int i = 0; i < stepY; i++)
        for (int j = 0; j < stepX; j++) blockDecoded[plane][(sbr >> sub) + i + 1][(sbc >> sub) + j + 1] = 1;
    if (plane > 0) {  // LoopfilterTxSizes for the chroma planes (luma uses mapTxSize)
        const int cs = MiCols >> 1, cr = MiRows >> 1;
        for (int i = 0; i < stepY && t.y4 + i < cr; i++)
            for (int j = 0; j < stepX && t.x4 + j < cs; j++) lfTxUV[plane - 1][(size_t)(t.y4 + i) * cs + t.x4 + j] = (uint8_t)txSz;
    }
}

// Deblocking (spec 7.14) then CDEF (7.15) on the reconstruction: the decoder's output frame.
// The maps come from this walk (independent of av1g_pf_mark_block, which the GPU path uses).
void Encoder::postfilter() {
    av1g_pf_frame f;
    memset(&f, 0, sizeof f);
    av1g_pf_frame_init(fp, &f);
    for (int p = 0; p < (mono ? 1 : 3); p++) { f.plane[p] = plane[p].data(); f.stride[p] = pstride[p]; }
    f.skip = mapSkip.data();
    f.lfTx[0] = mapTxSize.data();
    f.lfTx[1] = lfTxUV[0].data();
    f.lfTx[2] = lfTxUV[1].data();
    f.cdefIdx = sbCdef.data();
    av1g_deblock_frame(&f);
    if (!fp->enable_cdef) return;
    std::vector<uint8_t> out[3];
    uint8_t *dst[3] = {nullptr, nullptr, nullptr};
    for (int p = 0; p < (mono ? 1 : 3); p++) {
        out[p].assign(plane[p].size(), 0);
        dst[p] = out[p].data();
    }
    av1g_cdef_frame(&f, dst, pstride);
    for (int p = 0; p < (mono ? 1 : 3); p++) plane[p].swap(out[p]);
}

// coeffs() (spec 5.11.39).  Write: q holds the levels, eob was computed by the
// caller.  Parse: q is zero on entry and receives the decoded levels.  Returns eob;
// txType (luma) is coded / decoded here.
template <class S>
int Encoder::code_coeffs(S &sk, int plane, int txSz, int &txType, int x4, int y4, int16_t *q, int eob) {
    const int ptype = plane > 0, sub = plane ? 1 : 0;
    const int txSzCtx = (AV1G_T(Tx_Size_Sqr)[txSz] + AV1G_T(Tx_Size_Sqr_Up)[txSz] + 1) >> 1;
    const int w = AV1G_T(Tx_Width)[txSz], h = AV1G_T(Tx_Height)[txSz];
    const int w4 = w >> 2, h4 = h >> 2;
    const int maxX4 = MiCols >> sub, maxY4 = MiRows >> sub;
    uint8_t *aL = aboveLevel[plane].data(), *aD = aboveDc[plane].data();
    uint8_t *lL = leftLevel[plane].data(), *lD = leftDc[plane].data();

    // all_zero context
    int ctx;
    {
        const int bsz = plane ? av1g_uv_bsize(MiSize) : MiSize;
        const int bw = 4 * av1g_bw4(bsz), bh = 4 * av1g_bh4(bsz);
        if (plane == 0) {
            int top = 0, left = 0;
            for (int k = 0; k < w4; k++) if (x4 + k < maxX4 && aL[x4 + k] > top) top = aL[x4 + k];
            for (int k = 0; k < h4; k++) if (y4 + k < maxY4 && lL[y4 + k] > left) left = lL[y4 + k];
            if (top > 255) top = 255;
            if (left > 255) left = 255;
            const int mx = top > left ? top : left, mn = top < left ? top : left;
            if (bw == w && bh == h) ctx = 0;
            else if (top == 0 && left == 0) ctx = 1;
            else if (top == 0 || left == 0) ctx = 2 + (mx > 3);
            else if (mx <= 3) ctx = 4;
            else if (mn <= 3) ctx = 5;
            else ctx = 6;
        } else {
            int above = 0, left = 0;
            for (int i = 0; i < w4; i++) if (x4 + i < maxX4) above |= aL[x4 + i] | aD[x4 + i];
            for (int i = 0; i < h4; i++) if (y4 + i < maxY4) left |= lL[y4 + i] | lD[y4 + i];
            ctx = (above != 0) + (left != 0) + 7;
            if (bw * bh > w * h) ctx += 3;
        }
    }
    const int allZero = sk.sym(cdf.txb_skip[txSzCtx][ctx], eob == 0, 2);
    int culLevel = 0, dcCategory = 0;
    if (allZero) {
        eob = 0;
        if (plane == 0) txType = AV1G_DCT_DCT;
    } else {
        if (plane == 0) {  // transform_type()
            const int set = av1g_get_tx_set_intra(txSz, fp->reduced_tx_set);
            if (set > 0) {
                const int sqr = AV1G_T(Tx_Size_Sqr)[txSz];
                const int intraDir = B->filter_intra ? AV1G_T(Filter_Intra_Mode_To_Intra_Dir)[B->filter_intra - 1] : B->y_mode;
                if (set == AV1G_TX_SET_INTRA_1) {
                    int idx = 0;
                    for (int i = 0; i < 7; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set1)[i] == txType) idx = i;
                    idx = sk.sym(cdf.intra_tx_set1[sqr][intraDir], idx, 7);
                    txType = AV1G_T(Tx_Type_Intra_Inv_Set1)[idx];
                } else {
                    int idx = 0;
                    for (int i = 0; i < 5; i++) if (AV1G_T(Tx_Type_Intra_Inv_Set2)[i] == txType) idx = i;
                    idx = sk.sym(cdf.intra_tx_set2[sqr][intraDir], idx, 5);
                    txType = AV1G_T(Tx_Type_Intra_Inv_Set2)[idx];
                }
            } else {
                txType = AV1G_DCT_DCT;
            }
        }
        const uint16_t *scan = av1g_get_scan(txSz, txType);
        const int txClass = av1g_tx_class(txType);
        // eob
        const int eobMultisize = (AV1G_T(Tx_Width_Log2)[txSz] < 5 ? AV1G_T(Tx_Width_Log2)[txSz] : 5) +
                                 (AV1G_T(Tx_Height_Log2)[txSz] < 5 ? AV1G_T(Tx_Height_Log2)[txSz] : 5) - 4;
        int eobPtW = 1;
        if (S::kWrite) {
            if (eob <= 2) eobPtW = eob;
            else { eobPtW = 2; int v = eob - 1; while (v > 1) { v >>= 1; eobPtW++; } }
        }
        int eobPt;
        {
            const int ectx = txClass == AV1G_TX_CLASS_2D ? 0 : 1;
            const int N = eobMultisize + 5;
            uint16_t *c;
            switch (eobMultisize) {
            case 0: c = cdf.eob_pt_16[ptype][ectx]; break;
            case 1: c = cdf.eob_pt_32[ptype][ectx]; break;
            case 2: c = cdf.eob_pt_64[ptype][ectx]; break;
            case 3: c = cdf.eob_pt_128[ptype][ectx]; break;
            case 4: c = cdf.eob_pt_256[ptype][ectx]; break;
            case 5: c = cdf.eob_pt_512[ptype]; break;
            default: c = cdf.eob_pt_1024[ptype]; break;
            }
            eobPt = sk.sym(c, eobPtW - 1, N) + 1;
        }
        {
            const int eobW = eob;
            eob = (eobPt < 2) ? eobPt : ((1 << (eobPt - 2)) + 1);
            const int remW = eobW - eob;
            if (eobPt >= 3) {
                if (sk.sym(cdf.eob_extra[txSzCtx][ptype][eobPt - 3], (remW >> (eobPt - 3)) & 1, 2)) eob += 1 << (eobPt - 3);
                for (int i = 1; i < eobPt - 2; i++) {
                    const int sh = eobPt - 2 - 1 - i;
                    if (sk.bit((remW >> sh) & 1)) eob += 1 << sh;
                }
            }
        }
        if (eob > av1g_tx_coeffs(txSz)) throw Error(AV1G_ERR_INVALID, "eob %d out of range", eob);
        // levels (reverse scan order), contexts from already-coded levels
        const int adj = AV1G_T(Adjusted_Tx_Size)[txSz];
        const int bwl = AV1G_T(Tx_Width_Log2)[adj];
        const int width = 1 << bwl, height = AV1G_T(Tx_Height)[adj];
        uint8_t lev[1024];
        memset(lev, 0, sizeof(uint8_t) * (size_t)(width * height));
        for (int c = eob - 1; c >= 0; c--) {
            const int pos = scan[c];
            const int v = q[pos] < 0 ? -q[pos] : q[pos];
            const int levelW = v < 15 ? v : 15;
            const int row = pos >> bwl, col = pos - (row << bwl);
            int level;
            if (c == eob - 1) {
                int bctx;
                if (c == 0) bctx = 0;
                else if (c <= (height << bwl) / 8) bctx = 1;
                else if (c <= (height << bwl) / 4) bctx = 2;
                else bctx = 3;
                level = sk.sym(cdf.coeff_base_eob[txSzCtx][ptype][bctx], (levelW < 3 ? levelW : 3) - 1, 3) + 1;
            } else {
                int mag = 0;
                for (int idx = 0; idx < AV1G_SIG_REF_DIFF_OFFSET_NUM; idx++) {
                    const int rr = row + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][0];
                    const int cc = col + AV1G_T(Sig_Ref_Diff_Offset)[txClass][idx][1];
                    if (rr >= 0 && cc >= 0 && rr < height && cc < width) {
                        const int l = lev[(rr << bwl) + cc];
                        mag += l < 3 ? l : 3;
                    }
                }
                int bctx = (mag + 1) >> 1;
                if (bctx > 4) bctx = 4;
                if (txClass == AV1G_TX_CLASS_2D) {
                    if (row == 0 && col == 0) bctx = 0;
                    else bctx += AV1G_T(Coeff_Base_Ctx_Offset)[txSz][row < 4 ? row : 4][col < 4 ? col : 4];
                } else {
                    const int id = txClass == AV1G_TX_CLASS_VERT ? row : col;
                    bctx += AV1G_T(Coeff_Base_Pos_Ctx_Offset)[id < 2 ? id : 2];
                }
                level = sk.sym(cdf.coeff_base[txSzCtx][ptype][bctx], levelW < 3 ? levelW : 3, 4);
            }
            if (level > AV1G_NUM_BASE_LEVELS) {
                int mag = 0;
                for (int idx = 0; idx < 3; idx++) {
                    const int rr = row + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][0];
                    const int cc = col + AV1G_T(Mag_Ref_Offset_With_Tx_Class)[txClass][idx][1];
                    if (rr >= 0 && cc >= 0 && rr < height && cc < width) {
                        const int l = lev[rr * width + cc];
                        mag += l < 15 ? l : 15;
                    }
                }
                mag = (mag + 1) >> 1;
                if (mag > 6) mag = 6;
                int brctx;
                if (pos == 0) brctx = mag;
                else if (txClass == AV1G_TX_CLASS_2D) brctx = (row < 2 && col < 2) ? mag + 7 : mag + 14;
                else if (txClass == AV1G_TX_CLASS_HORIZ) brctx = col == 0 ? mag + 7 : mag + 14;
                else brctx = row == 0 ? mag + 7 : mag + 14;
                int remW = levelW - 3;
                const int brsz = txSzCtx < AV1G_TX_32X32 ? txSzCtx : AV1G_TX_32X32;
                for (int idx = 0; idx < AV1G_COEFF_BASE_RANGE / (AV1G_BR_CDF_SIZE - 1); idx++) {
                    const int k = sk.sym(cdf.coeff_br[brsz][ptype][brctx], remW < 3 ? remW : 3, AV1G_BR_CDF_SIZE);
                    level += k;
                    remW -= k;
                    if (k < AV1G_BR_CDF_SIZE - 1) break;
                }
            }
            lev[pos] = (uint8_t)level;
        }
        // signs and Golomb remainders (forward scan order)
        for (int c = 0; c < eob; c++) {
            const int pos = scan[c];
            if (lev[pos] == 0) continue;
            const int vW = q[pos];
            const int signW = vW < 0, aW = signW ? -vW : vW;
            int sign;
            if (c == 0) {
                int dcSign = 0;
                for (int k = 0; k < w4; k++)
                    if (x4 + k < maxX4) { if (aD[x4 + k] == 1) dcSign--; else if (aD[x4 + k] == 2) dcSign++; }
                for (int k = 0; k < h4; k++)
                    if (y4 + k < maxY4) { if (lD[y4 + k] == 1) dcSign--; else if (lD[y4 + k] == 2) dcSign++; }
                const int dctx = dcSign < 0 ? 1 : dcSign > 0 ? 2 : 0;
                sign = sk.sym(cdf.dc_sign[ptype][dctx], signW, 2);
            } else {
                sign = sk.bit(signW);
            }
            int a = lev[pos];
            if (a > AV1G_NUM_BASE_LEVELS + AV1G_COEFF_BASE_RANGE) {
                const uint32_t xW = S::kWrite ? (uint32_t)(aW - (AV1G_NUM_BASE_LEVELS + AV1G_COEFF_BASE_RANGE)) : 1;
                int lenW = 0;
                while ((xW >> lenW) > 1) lenW++;  // floor(log2 x)
                int length = 0;
                for (;;) {  // golomb_length_bit
                    length++;
                    if (sk.bit(length - 1 == lenW)) break;
                    if (length > 20) throw Error(AV1G_ERR_INVALID, "golomb length > 20");
                }
                uint32_t x = 1;
                for (int i = length - 2; i >= 0; i--) x = (x << 1) | (uint32_t)sk.bit((xW >> i) & 1);
                a = (int)(x + AV1G_COEFF_BASE_RANGE + AV1G_NUM_BASE_LEVELS);
            }
            a &= 0xFFFFF;
            if (!S::kWrite) {
                if (a > 32767) throw Error(AV1G_ERR_INVALID, "coefficient %d does not fit the int16 record", a);
                q[pos] = (int16_t)(sign ? -a : a);
            }
            if (pos == 0) dcCategory = sign ? 1 : 2;
            culLevel += a;
        }
        if (culLevel > 63) culLevel = 63;
    }
    for (int i = 0; i < w4; i++) { aL[x4 + i] = (uint8_t)culLevel; aD[x4 + i] = (uint8_t)dcCategory; }
    for (int i = 0; i < h4; i++) { lL[y4 + i] = (uint8_t)culLevel; lD[y4 + i] = (uint8_t)dcCategory; }
    return eob;
}

template <class S>
void Encoder::encode_tile(S &sk, int tileRow, int tileCol) {
    miRowStart = tiles.miRowStarts[tileRow];
    miRowEnd = tiles.miRowStarts[tileRow + 1];
    miColStart = tiles.miColStarts[tileCol];
    miColEnd = tiles.miColStarts[tileCol + 1];
    av1g_cdfs_init(&cdf, fp->base_q_idx);
    CurrentQIndex = fp->base_q_idx;
    for (int p = 0; p < 3; p++) {
        std::fill(aboveLevel[p].begin(), aboveLevel[p].end(), 0);
        std::fill(aboveDc[p].begin(), aboveDc[p].end(), 0);
    }
    for (int r = miRowStart; r < miRowEnd; r += 16) {
        for (int p = 0; p < 3; p++) {
            std::fill(leftLevel[p].begin(), leftLevel[p].end(), 0);
            std::fill(leftDc[p].begin(), leftDc[p].end(), 0);
        }
        for (int c = miColStart; c < miColEnd; c += 16) {
            readDeltas = fp->delta_q_present;
            sbIndex = (r >> 4) * sbCols + (c >> 4);
            sbCdef[sbIndex] = -1;  // clear_cdef
            clear_block_decoded(r, c);
            encode_partition(sk, r, c, AV1G_BLOCK_64X64);
        }
    }
}

void Encoder::write_headers(BitWriter &seq, BitWriter &fh, int level) {
    // ---- sequence_header_obu (reduced still picture) ----
    const int diff_uv = (fp->delta_q_v_dc != fp->delta_q_u_dc || fp->delta_q_v_ac != fp->delta_q_u_ac);
    const int separate_uv = !mono && (diff_uv || (fp->using_qmatrix && fp->qm_v != fp->qm_u));
    seq.put(0, 3);          // seq_profile = Main
    seq.put(1, 1);          // still_picture
    seq.put(1, 1);          // reduced_still_picture_header
    seq.put(level, 5);      // seq_level_idx[0]
    int wb = 1, hb = 1;
    while ((uint32_t)(W - 1) >> wb) wb++;
    while ((uint32_t)(H - 1) >> hb) hb++;
    seq.put(wb - 1, 4);     // frame_width_bits_minus_1
    seq.put(hb - 1, 4);
    seq.put(W - 1, wb);     // max_frame_width_minus_1
    seq.put(H - 1, hb);
    seq.put(0, 1);          // use_128x128_superblock
    seq.put(fp->enable_filter_intra, 1);       // enable_filter_intra
    seq.put(fp->enable_intra_edge_filter, 1);  // enable_intra_edge_filter
    seq.put(0, 1);          // enable_superres
    seq.put(fp->enable_cdef, 1);  // enable_cdef
    seq.put(0, 1);          // enable_restoration
    // color_config
    seq.put(0, 1);          // high_bitdepth
    seq.put(mono, 1);       // mono_chrome
    seq.put(1, 1);          // color_description_present_flag
    seq.put(1, 8);          // color_primaries = CP_BT_709
    seq.put(13, 8);         // transfer_characteristics = TC_SRGB
    seq.put(6, 8);          // matrix_coefficients = MC_BT_601
    seq.put(1, 1);          // color_range = full
    if (!mono) {
        seq.put(0, 2);      // chroma_sample_position = CSP_UNKNOWN
        seq.put(separate_uv, 1);  // separate_uv_delta_q
    }
    seq.put(0, 1);          // film_grain_params_present
    seq.trailing_bits();

    // ---- uncompressed_header (reduced_still_picture_header) ----
    fh.put(0, 1);           // disable_cdf_update
    fh.put(fp->allow_screen_content_tools, 1);  // allow_screen_content_tools
    if (fp->allow_screen_content_tools) fh.put(0, 1);  // force_integer_mv (overridden to 1 for intra frames)
    fh.put(0, 1);           // render_and_frame_size_different
    if (fp->allow_screen_content_tools) fh.put(0, 1);  // allow_intrabc
    // tile_info
    fh.put(1, 1);           // uniform_tile_spacing_flag
    for (int k = tiles.minLog2TileCols; k < tiles.maxLog2TileCols; k++) {
        if (k < tiles.colsLog2) fh.put(1, 1);
        else { fh.put(0, 1); break; }
    }
    for (int k = tiles.minLog2TileRows; k < tiles.maxLog2TileRows; k++) {
        if (k < tiles.rowsLog2) fh.put(1, 1);
        else { fh.put(0, 1); break; }
    }
    if (tiles.colsLog2 > 0 || tiles.rowsLog2 > 0) {
        fh.put(0, tiles.colsLog2 + tiles.rowsLog2);  // context_update_tile_id
        fh.put(tiles.tileSizeBytes - 1, 2);          // tile_size_bytes_minus_1
    }
    // quantization_params
    fh.put(fp->base_q_idx, 8);
    auto delta_q = [&](int v) {
        if (v) { fh.put(1, 1); fh.su(v, 7); } else fh.put(0, 1);
    };
    delta_q(fp->delta_q_y_dc);
    if (!mono) {
        if (separate_uv) fh.put(diff_uv, 1);  // diff_uv_delta
        delta_q(fp->delta_q_u_dc);
        delta_q(fp->delta_q_u_ac);
        if (diff_uv) {
            delta_q(fp->delta_q_v_dc);
            delta_q(fp->delta_q_v_ac);
        }
    }
    fh.put(fp->using_qmatrix, 1);  // using_qmatrix
    if (fp->using_qmatrix) {
        fh.put(fp->qm_y, 4);
        fh.put(fp->qm_u, 4);
        if (separate_uv) fh.put(fp->qm_v, 4);
    }
    fh.put(0, 1);           // segmentation_enabled
    fh.put(fp->delta_q_present, 1);  // delta_q_present (base_q_idx > 0)
    if (fp->delta_q_present) {
        fh.put(fp->delta_q_res, 2);  // delta_q_res
        fh.put(0, 1);                // delta_lf_present
    }
    // loop_filter_params (effective levels; ref deltas off)
    fh.put(fp->loop_filter_level[0], 6);
    fh.put(fp->loop_filter_level[1], 6);
    if (!mono && (fp->loop_filter_level[0] || fp->loop_filter_level[1])) {
        fh.put(fp->loop_filter_level[2], 6);
        fh.put(fp->loop_filter_level[3], 6);
    }
    fh.put(fp->loop_filter_sharpness, 3);
    fh.put(0, 1);           // loop_filter_delta_enabled
    if (fp->enable_cdef) {  // cdef_params
        fh.put(fp->cdef_damping_minus_3, 2);
        fh.put(fp->cdef_bits, 2);
        for (int i = 0; i < (1 << fp->cdef_bits); i++) {
            fh.put(fp->cdef_y_pri[i], 4);
            fh.put(fp->cdef_y_sec[i] == 4 ? 3 : fp->cdef_y_sec[i], 2);
            if (!mono) {
                fh.put(fp->cdef_uv_pri[i], 4);
                fh.put(fp->cdef_uv_sec[i] == 4 ? 3 : fp->cdef_uv_sec[i], 2);
            }
        }
    }
    // lr_params: disabled in sequence header
    fh.put(fp->tx_mode_select ? 1 : 0, 1);  // tx_mode_select
    fh.put(fp->reduced_tx_set ? 1 : 0, 1);  // reduced_tx_set
    fh.byte_align();
}

void Encoder::setup_frame() {
    fp = &R->fp;
    W = fp->width; H = fp->height;
    mono = fp->monochrome;
    MiCols = av1g_mi_cols(W); MiRows = av1g_mi_rows(H);
    sbCols = (MiCols + 15) >> 4; sbRows = (MiRows + 15) >> 4;
    if (!compute_tiles(W, H, fp->tile_cols_log2, fp->tile_rows_log2, tiles))
        throw Error(AV1G_ERR_INVALID, "illegal tiling %d/%d for %dx%d", fp->tile_cols_log2, fp->tile_rows_log2, W, H);
    blockQ = -1;
    set_block_q(fp->base_q_idx);
    qmLevel[0] = fp->qm_y;
    qmLevel[1] = fp->qm_u;
    qmLevel[2] = (!mono && fp->using_qmatrix) ? fp->qm_v : fp->qm_u;
    for (int p = 0; p < (mono ? 1 : 3); p++) {
        const int sub = p ? 1 : 0;
        pstride[p] = (sbCols * 64) >> sub;
        pheight[p] = (sbRows * 64) >> sub;
        if (doRecon) plane[p].assign((size_t)pstride[p] * pheight[p], 0);
    }
    const size_t nmi = (size_t)MiRows * MiCols;
    mapMiSize.assign(nmi, 0); mapYMode.assign(nmi, 0); mapSkip.assign(nmi, 0); mapTxSize.assign(nmi, 0); mapUVMode.assign(nmi, 0);
    lfTxUV[0].assign((size_t)(MiRows >> 1) * (MiCols >> 1), 0);
    lfTxUV[1].assign((size_t)(MiRows >> 1) * (MiCols >> 1), 0);
    sbCdef.assign((size_t)sbCols * sbRows, -1);
    for (int p = 0; p < 3; p++) {
        aboveLevel[p].assign(MiCols + 32, 0); aboveDc[p].assign(MiCols + 32, 0);
        leftLevel[p].assign(MiRows + 32, 0); leftDc[p].assign(MiRows + 32, 0);
    }
}

void Encoder::run(av1g_output *out) {
    fp = &R->fp;
    if (fp->version != AV1G_DECISIONS_VERSION) throw Error(AV1G_ERR_INVALID, "record version %u != %d", fp->version, AV1G_DECISIONS_VERSION);
    if (fp->width < 1 || fp->height < 1 || fp->width > 65535 || fp->height > 65535)
        throw Error(AV1G_ERR_INVALID, "bad size %ux%u", fp->width, fp->height);
    if (fp->base_q_idx < 1) throw Error(AV1G_ERR_INVALID, "base_q_idx must be >= 1 (lossless unsupported)");
    if (fp->monochrome > 1 || fp->tx_mode_select > 1 || fp->reduced_tx_set > 1) throw Error(AV1G_ERR_INVALID, "bad frame flags");
    const int8_t dqs[5] = {fp->delta_q_y_dc, fp->delta_q_u_dc, fp->delta_q_u_ac, fp->delta_q_v_dc, fp->delta_q_v_ac};
    for (int i = 0; i < 5; i++) if (dqs[i] < -64 || dqs[i] > 63) throw Error(AV1G_ERR_INVALID, "delta_q out of range");
    {
        if (fp->enable_filter_intra > 1 || fp->enable_intra_edge_filter > 1)
            throw Error(AV1G_ERR_INVALID, "enable_filter_intra / enable_intra_edge_filter must be 0/1");
        for (int i = 0; i < 4; i++)
            if (fp->loop_filter_level[i] > 63) throw Error(AV1G_ERR_INVALID, "loop_filter_level > 63");
        if (fp->loop_filter_sharpness > 7) throw Error(AV1G_ERR_INVALID, "loop_filter_sharpness > 7");
        if (!fp->loop_filter_level[0] && !fp->loop_filter_level[1] && (fp->loop_filter_level[2] || fp->loop_filter_level[3]))
            throw Error(AV1G_ERR_INVALID, "chroma loop filter levels need a nonzero luma level (spec loop_filter_params)");
        if (fp->enable_cdef > 1 || fp->cdef_damping_minus_3 > 3 || fp->cdef_bits > 3)
            throw Error(AV1G_ERR_INVALID, "bad CDEF parameters");
        for (int i = 0; i < 8; i++) {
            auto secOk = [](int v) { return v == 0 || v == 1 || v == 2 || v == 4; };
            if (fp->cdef_y_pri[i] > 15 || fp->cdef_uv_pri[i] > 15 || !secOk(fp->cdef_y_sec[i]) || !secOk(fp->cdef_uv_sec[i]))
                throw Error(AV1G_ERR_INVALID, "CDEF strengths: pri 0..15, sec 0/1/2/4");
        }
        if (fp->delta_q_present > 1 || fp->delta_q_res > 3 || fp->using_qmatrix > 1 || fp->qm_y > 15 || fp->qm_u > 15 ||
            fp->qm_v > 15)
            throw Error(AV1G_ERR_INVALID, "bad delta_q / quantizer matrix parameters");
        for (int i = 0; i < (int)sizeof fp->reserved; i++)
            if (fp->reserved[i]) throw Error(AV1G_ERR_INVALID, "reserved frame_params fields must be 0 in interface v1");
        if (fp->allow_screen_content_tools > 1) throw Error(AV1G_ERR_INVALID, "allow_screen_content_tools must be 0/1");
    }
    doRecon = !(opts.flags & AV1G_ENC_SKIP_RECON);
    fixRange = (opts.flags & AV1G_ENC_FIX_RANGE) != 0;
    if (!R->blocks || !R->block_txb || !R->txb || (!R->coeffs && R->n_coeffs))
        throw Error(AV1G_ERR_INVALID, "record arrays missing");
    if (R->block_txb[R->n_blocks] != R->n_txb) throw Error(AV1G_ERR_INVALID, "layout stale (call av1g_layout)");
    setup_frame();
    if (opts.flags & AV1G_ENC_CHECK_EDGES) {
        for (int p = 0; p < (mono ? 1 : 3); p++) {
            const int sub = p ? 1 : 0, stride = (sbCols * 16) >> sub, rows = (sbRows * 16) >> sub;
            ordMap[p].assign((size_t)stride * rows, 0xFFFFFFFFu);
        }
        for (uint32_t i = 0; i < R->n_txb; i++) {
            const av1g_txb &x = R->txb[i];
            const int sub = x.plane ? 1 : 0, stride = (sbCols * 16) >> sub, rows = (sbRows * 16) >> sub;
            const int w4 = av1g_tx_w(x.tx_size) >> 2, h4 = av1g_tx_h(x.tx_size) >> 2;
            for (int yy = 0; yy < h4 && x.y4 + yy < rows; yy++)
                for (int xx = 0; xx < w4 && x.x4 + xx < stride; xx++) ordMap[x.plane][(size_t)(x.y4 + yy) * stride + x.x4 + xx] = i;
        }
    }

    // ---- tiles ----
    // Every tile's blocks: all blocks whose position is inside it, contiguous in tile order.
    const uint32_t ntilesAll = tiles.rows * tiles.cols;
    std::vector<uint32_t> tileFirst(ntilesAll + 1, 0);
    cursor = 0;
    for (uint32_t tr = 0; tr < tiles.rows; tr++)
        for (uint32_t tc = 0; tc < tiles.cols; tc++) {
            tileFirst[tr * tiles.cols + tc] = cursor;
            while (cursor < R->n_blocks) {
                const av1g_block &b = R->blocks[cursor];
                if (b.mi_row < tiles.miRowStarts[tr] || b.mi_row >= tiles.miRowStarts[tr + 1] ||
                    b.mi_col < tiles.miColStarts[tc] || b.mi_col >= tiles.miColStarts[tc + 1]) break;
                cursor++;
            }
        }
    tileFirst[ntilesAll] = cursor;
    if (cursor != R->n_blocks) throw Error(AV1G_ERR_INVALID, "block %u is outside the expected tile order", cursor);
    std::vector<std::vector<uint8_t>> tileData(ntilesAll);
    std::vector<uint64_t> tileSymbols(ntilesAll, 0), tileFixed(ntilesAll, 0);
    // Glass Act: one tile's coding, by a copy of this encoder (its own tile state, the shared frame)
    if (skipTiles && skipTiles->size() != ntilesAll) throw Error(AV1G_ERR_INVALID, "tile skip list of %zu for %u tiles", skipTiles->size(), ntilesAll);
    auto codeTile = [&](Encoder &e, uint32_t i) {
        const uint32_t tr = i / tiles.cols, tc = i % tiles.cols;
        if (skipTiles && (*skipTiles)[i].skip) {  // the caller has this tile
            if ((*skipTiles)[i].payload) tileData[i] = *(*skipTiles)[i].payload;
            return;
        }
        e.cursor = tileFirst[i];
        e.tileEnd = tileFirst[i + 1];
        e.nFixed = 0;
        if (tileSyms) {
            TeeSink sk((const uint16_t *)&e.cdf, &(*tileSyms)[i]);
            e.encode_tile(sk, tr, tc);
            tileSymbols[i] = sk.nsym;
            tileData[i] = sk.finish();
        } else {
            EcSink sk;
            e.encode_tile(sk, tr, tc);
            tileSymbols[i] = sk.nsym;
            tileData[i] = sk.finish();
        }
        tileFixed[i] = e.nFixed;
        if (e.cursor != e.tileEnd)
            throw Error(AV1G_ERR_INVALID, "tile %u,%u: block %u not consumed by the partition walk", tr, tc, e.cursor);
    };
    if (tileSyms) tileSyms->assign(ntilesAll, {});
    const unsigned hw = std::max(1u, std::thread::hardware_concurrency());
    const uint32_t nworkers = ntilesAll > 1 ? std::min<uint32_t>(ntilesAll, hw) : 1;
    if (nworkers == 1) {
        for (uint32_t i = 0; i < ntilesAll; i++) codeTile(*this, i);
    } else {
        std::atomic<uint32_t> next{0};
        std::vector<std::string> errors(nworkers);
        std::vector<int> codes(nworkers, 0);
        std::vector<std::thread> workers;
        for (uint32_t w = 0; w < nworkers; w++)
            workers.emplace_back([&, w]() {
                Encoder e(*this);  // shares frameBufs, R and the hook; owns its tile state
                try {
                    for (;;) {
                        const uint32_t i = next.fetch_add(1);
                        if (i >= ntilesAll) break;
                        codeTile(e, i);
                    }
                } catch (const Error &x) {
                    codes[w] = x.code;
                    errors[w] = x.what();
                    next = ntilesAll;
                } catch (const std::exception &x) {
                    codes[w] = AV1G_ERR_INTERNAL;
                    errors[w] = x.what();
                    next = ntilesAll;
                }
            });
        for (auto &t : workers) t.join();
        for (uint32_t w = 0; w < nworkers; w++)
            if (codes[w]) throw Error(codes[w], "%s", errors[w].c_str());
    }
    if (tilePayloadsOut) *tilePayloadsOut = tileData;
    uint64_t nsym = 0;
    nFixed = 0;
    for (uint32_t i = 0; i < ntilesAll; i++) { nsym += tileSymbols[i]; nFixed += tileFixed[i]; }

    const int ntiles = (int)tileData.size();
    // TileSizeBytes: smallest that holds every tile_size_minus_1 except the last tile's
    uint64_t maxSz = 0;
    for (int i = 0; i + 1 < ntiles; i++) if (tileData[i].size() - 1 > maxSz) maxSz = tileData[i].size() - 1;
    tiles.tileSizeBytes = maxSz < (1u << 8) ? 1 : maxSz < (1u << 16) ? 2 : maxSz < (1u << 24) ? 3 : 4;

    int level = opts.seq_level_idx >= 0 ? opts.seq_level_idx : choose_level(W, H, ntiles, tiles.cols);
    BitWriter seq, fh;
    write_headers(seq, fh, level);
    // tile group
    std::vector<uint8_t> frame = fh.buf;
    if (ntiles > 1) frame.push_back(0);  // tile_start_and_end_present_flag = 0 + byte_alignment
    uint64_t tileBytes = 0;
    for (int i = 0; i < ntiles; i++) {
        if (i + 1 < ntiles) {
            uint64_t v = tileData[i].size() - 1;
            for (int k = 0; k < tiles.tileSizeBytes; k++) frame.push_back((uint8_t)(v >> (8 * k)));
        }
        frame.insert(frame.end(), tileData[i].begin(), tileData[i].end());
        tileBytes += tileData[i].size();
    }
    std::vector<uint8_t> obu;
    if (opts.flags & AV1G_ENC_TD) { obu.push_back(0x12); obu.push_back(0x00); }
    obu.push_back(0x0A);  // OBU_SEQUENCE_HEADER, has_size_field
    put_leb128(obu, seq.buf.size());
    obu.insert(obu.end(), seq.buf.begin(), seq.buf.end());
    obu.push_back(0x32);  // OBU_FRAME, has_size_field
    put_leb128(obu, frame.size());
    obu.insert(obu.end(), frame.begin(), frame.end());

    out->obu = (uint8_t *)malloc(obu.size());
    memcpy(out->obu, obu.data(), obu.size());
    out->obu_size = obu.size();
    out->seq_level_idx = level;
    out->tile_cols = tiles.cols;
    out->tile_rows = tiles.rows;
    out->tile_bytes = tileBytes;
    out->header_bytes = (uint32_t)(obu.size() - tileBytes);
    out->n_symbols = nsym;
    out->n_fixed_txb = (uint32_t)nFixed;
    if (opts.flags & AV1G_ENC_AVIF) {
        // AVIF item data never carries a temporal delimiter
        const size_t skip = (opts.flags & AV1G_ENC_TD) ? 2 : 0;
        if (av1g_mux_avif(out->obu + skip, out->obu_size - skip, W, H, &out->avif, &out->avif_size) != AV1G_OK)
            throw Error(AV1G_ERR_INTERNAL, "AVIF mux failed");
    }
    if (doRecon && !(opts.flags & AV1G_ENC_NO_RECON)) {
        if (!(opts.flags & AV1G_ENC_PREFILTER_RECON)) postfilter();
        for (int p = 0; p < (mono ? 1 : 3); p++) {
            const int sub = p ? 1 : 0;
            // pre-filter recon keeps the decoded area up to MiCols*4 x MiRows*4: the filters read it
            const bool pad = opts.flags & AV1G_ENC_PREFILTER_RECON;
            const int w = pad ? (MiCols * 4) >> sub : (W + sub) >> sub, h = pad ? (MiRows * 4) >> sub : (H + sub) >> sub;
            out->recon[p] = (uint8_t *)malloc((size_t)w * h);
            out->recon_w[p] = w;
            out->recon_h[p] = h;
            for (int y = 0; y < h; y++) memcpy(out->recon[p] + (size_t)y * w, plane[p].data() + (size_t)y * pstride[p], w);
        }
    }
}

// ---------------------------------------------------------------------------
// parsing: OBUs -> DecisionRecord (Wave-1 intra toolset only)
// ---------------------------------------------------------------------------
namespace {
struct BitReader {
    const uint8_t *d;
    size_t n, pos = 0;
    BitReader(const uint8_t *d_, size_t n_) : d(d_), n(n_) {}
    uint32_t f(int k) {
        uint32_t v = 0;
        for (int i = 0; i < k; i++, pos++) {
            if ((pos >> 3) >= n) throw Error(AV1G_ERR_INVALID, "header truncated");
            v = (v << 1) | ((d[pos >> 3] >> (7 - (pos & 7))) & 1);
        }
        return v;
    }
    int su(int k) { int v = (int)f(k); int m = 1 << (k - 1); return (v & m) ? v - 2 * m : v; }
    void byte_align() { pos = (pos + 7) & ~(size_t)7; }
};
#define NEED(cond, ...) do { if (!(cond)) throw Error(AV1G_ERR_INVALID, __VA_ARGS__); } while (0)
}  // namespace

void Encoder::parse(const uint8_t *obus, size_t n) {
    struct Seq {
        bool seen = false;
        int reduced = 0, level = 0, wbits = 0, hbits = 0, maxW = 0, maxH = 0, filterIntra = 0, edgeFilter = 0;
        int superres = 0, cdef = 0, restoration = 0, mono = 0, separateUv = 0, forceSct = 2, forceIntMv = 2;
        int orderHintBits = 0, frameIds = 0, filmGrain = 0, decoderModel = 0;
    } sq;
    av1g_frame_params &F = R->fp;
    memset(&F, 0, sizeof F);
    F.version = AV1G_DECISIONS_VERSION;
    size_t pos = 0;
    bool done = false;
    while (pos < n && !done) {
        const uint8_t h = obus[pos++];
        const int type = (h >> 3) & 15, ext = (h >> 2) & 1, hasSize = (h >> 1) & 1;
        if (ext) pos++;
        uint64_t sz = n - pos;
        if (hasSize) {
            sz = 0;
            for (int i = 0; i < 8; i++) {
                NEED(pos < n, "OBU truncated");
                uint8_t b = obus[pos++];
                sz |= (uint64_t)(b & 0x7f) << (7 * i);
                if (!(b & 0x80)) break;
            }
        }
        NEED(pos + sz <= n, "OBU size beyond buffer");
        const uint8_t *p = obus + pos;
        if (type == 1) {  // sequence header
            BitReader br(p, (size_t)sz);
            int profile = br.f(3);
            br.f(1);  // still_picture
            sq.reduced = br.f(1);
            NEED(profile == 0, "only Main profile (got %d)", profile);
            if (sq.reduced) {
                sq.level = br.f(5);
            } else {
                int timing = br.f(1);
                if (timing) {
                    br.f(32); br.f(32);
                    if (br.f(1)) {  // equal_picture_interval: uvlc
                        int lz = 0;
                        while (!br.f(1)) lz++;
                        if (lz < 32) br.f(lz);
                    }
                    sq.decoderModel = br.f(1);
                    NEED(!sq.decoderModel, "decoder model info not supported");
                }
                int idd = br.f(1);
                int nops = br.f(5) + 1;
                for (int i = 0; i < nops; i++) {
                    br.f(12);
                    int lv = br.f(5);
                    if (i == 0) sq.level = lv;
                    if (lv > 7) br.f(1);
                    if (idd && br.f(1)) br.f(4);
                }
            }
            sq.wbits = br.f(4) + 1;
            sq.hbits = br.f(4) + 1;
            sq.maxW = br.f(sq.wbits) + 1;
            sq.maxH = br.f(sq.hbits) + 1;
            if (!sq.reduced) {
                sq.frameIds = br.f(1);
                NEED(!sq.frameIds, "frame ids not supported");
            }
            NEED(br.f(1) == 0, "128x128 superblocks not supported");
            sq.filterIntra = br.f(1);
            sq.edgeFilter = br.f(1);
            if (!sq.reduced) {
                br.f(1); br.f(1); br.f(1); br.f(1);  // interintra, masked, warped, dual filter
                int oh = br.f(1);
                if (oh) { br.f(1); br.f(1); }
                if (br.f(1)) sq.forceSct = 2; else sq.forceSct = br.f(1);
                if (sq.forceSct > 0) { if (br.f(1)) sq.forceIntMv = 2; else sq.forceIntMv = br.f(1); }
                else sq.forceIntMv = 2;
                if (oh) sq.orderHintBits = br.f(3) + 1;
            }
            sq.superres = br.f(1);
            sq.cdef = br.f(1);
            sq.restoration = br.f(1);
            NEED(br.f(1) == 0, "only 8-bit supported");
            sq.mono = br.f(1);
            int cp = 2, tc = 2, mc = 2;
            if (br.f(1)) { cp = br.f(8); tc = br.f(8); mc = br.f(8); }
            if (sq.mono) {
                br.f(1);
            } else {
                NEED(!(cp == 1 && tc == 13 && mc == 0), "4:4:4 identity matrix not supported");
                br.f(1);  // color_range
                br.f(2);  // chroma_sample_position
                sq.separateUv = br.f(1);
            }
            sq.filmGrain = br.f(1);
            sq.seen = true;
        } else if (type == 6 || type == 3) {  // frame / frame header
            NEED(sq.seen, "frame before sequence header");
            NEED(type == 6, "separate frame header + tile group OBUs not supported");
            F.enable_intra_edge_filter = (uint8_t)sq.edgeFilter;
            F.enable_filter_intra = (uint8_t)sq.filterIntra;
            NEED(!sq.superres && !sq.filmGrain, "superres / film grain not supported");
            BitReader br(p, (size_t)sz);
            if (!sq.reduced) {
                NEED(br.f(1) == 0, "show_existing_frame");
                NEED(br.f(2) == 0, "only KEY_FRAME supported");
                NEED(br.f(1) == 1, "show_frame must be 1");
            }
            NEED(br.f(1) == 0, "disable_cdf_update=1 not supported");
            int sct = sq.forceSct;
            if (sq.forceSct == 2) sct = br.f(1);
            F.allow_screen_content_tools = (uint8_t)(sct ? 1 : 0);
            if (sct && sq.forceIntMv == 2) br.f(1);  // force_integer_mv
            int override_ = 0;
            if (!sq.reduced) override_ = br.f(1);
            if (sq.orderHintBits) br.f(sq.orderHintBits);
            int fw = sq.maxW, fh = sq.maxH;
            if (override_) { fw = br.f(sq.wbits) + 1; fh = br.f(sq.hbits) + 1; }
            if (br.f(1)) { br.f(16); br.f(16); }  // render size
            if (sct) NEED(br.f(1) == 0, "allow_intrabc=1 not supported");
            int disableFrameEndUpdate = 1;
            if (!sq.reduced) disableFrameEndUpdate = br.f(1);
            (void)disableFrameEndUpdate;
            F.width = fw;
            F.height = fh;
            F.monochrome = (uint8_t)sq.mono;
            int tileSizeBytes = 4;
            // tile_info
            {
                TileInfo t;
                compute_tiles(fw, fh, -1, -1, t);
                NEED(br.f(1) == 1, "non-uniform tile spacing not supported");
                int cl = t.minLog2TileCols;
                while (cl < t.maxLog2TileCols) { if (br.f(1)) cl++; else break; }
                TileInfo t2;
                compute_tiles(fw, fh, cl, -1, t2);
                int rl = t2.minLog2TileRows;
                while (rl < t2.maxLog2TileRows) { if (br.f(1)) rl++; else break; }
                F.tile_cols_log2 = (int8_t)cl;
                F.tile_rows_log2 = (int8_t)rl;
                if (cl > 0 || rl > 0) {
                    br.f(cl + rl);  // context_update_tile_id (irrelevant: no frame-end CDF update)
                    tileSizeBytes = br.f(2) + 1;
                }
            }
            // quantization_params
            F.base_q_idx = (uint8_t)br.f(8);
            auto rdq = [&]() { return br.f(1) ? br.su(7) : 0; };
            F.delta_q_y_dc = (int8_t)rdq();
            if (!sq.mono) {
                int diff = sq.separateUv ? br.f(1) : 0;
                F.delta_q_u_dc = (int8_t)rdq();
                F.delta_q_u_ac = (int8_t)rdq();
                if (diff) { F.delta_q_v_dc = (int8_t)rdq(); F.delta_q_v_ac = (int8_t)rdq(); }
                else { F.delta_q_v_dc = F.delta_q_u_dc; F.delta_q_v_ac = F.delta_q_u_ac; }
            }
            F.using_qmatrix = (uint8_t)br.f(1);
            if (F.using_qmatrix) {
                F.qm_y = (uint8_t)br.f(4);
                F.qm_u = (uint8_t)br.f(4);
                F.qm_v = sq.separateUv ? (uint8_t)br.f(4) : F.qm_u;
            }
            NEED(br.f(1) == 0, "segmentation not supported");
            NEED(F.base_q_idx > 0, "lossless not supported");
            F.delta_q_present = (uint8_t)br.f(1);
            if (F.delta_q_present) {
                F.delta_q_res = (uint8_t)br.f(2);
                NEED(br.f(1) == 0, "delta_lf_present (M5) not supported");
            }
            // loop_filter_params -> effective levels (intra frame: only the INTRA ref delta applies)
            int lvl[4] = {0, 0, 0, 0};
            lvl[0] = br.f(6);
            lvl[1] = br.f(6);
            if (!sq.mono && (lvl[0] || lvl[1])) { lvl[2] = br.f(6); lvl[3] = br.f(6); }
            F.loop_filter_sharpness = (uint8_t)br.f(3);
            int refDeltaIntra = 1;  // setup_past_independence default
            const int deltaEnabled = br.f(1);
            if (deltaEnabled) {
                if (br.f(1)) {
                    for (int i = 0; i < 8; i++) if (br.f(1)) { int v = br.su(7); if (i == 0) refDeltaIntra = v; }
                    for (int i = 0; i < 2; i++) if (br.f(1)) br.su(7);
                }
            }
            if (lvl[0] || lvl[1]) {
                for (int i = 0; i < 4; i++) {
                    if (i >= 2 && !lvl[i]) continue;  // chroma plane not filtered at all
                    int e = lvl[i];
                    if (deltaEnabled) e = av1g_clip3(0, 63, e + refDeltaIntra * (1 << (e >> 5)));
                    F.loop_filter_level[i] = (uint8_t)e;
                }
                NEED(F.loop_filter_level[0] || F.loop_filter_level[1] || (!F.loop_filter_level[2] && !F.loop_filter_level[3]),
                     "loop filter delta combination not representable");
            }
            if (sq.cdef) {
                F.enable_cdef = 1;
                F.cdef_damping_minus_3 = (uint8_t)br.f(2);
                F.cdef_bits = (uint8_t)br.f(2);
                for (int i = 0; i < (1 << F.cdef_bits); i++) {
                    F.cdef_y_pri[i] = (uint8_t)br.f(4);
                    int ys = br.f(2);
                    F.cdef_y_sec[i] = (uint8_t)(ys == 3 ? 4 : ys);
                    if (!sq.mono) {
                        F.cdef_uv_pri[i] = (uint8_t)br.f(4);
                        int us = br.f(2);
                        F.cdef_uv_sec[i] = (uint8_t)(us == 3 ? 4 : us);
                    }
                }
            }
            if (sq.restoration)
                for (int i = 0; i < (sq.mono ? 1 : 3); i++) NEED(br.f(2) == 0, "loop restoration not supported");
            F.tx_mode_select = (uint8_t)br.f(1);
            F.reduced_tx_set = (uint8_t)br.f(1);
            br.byte_align();
            setup_frame();
            tiles.tileSizeBytes = tileSizeBytes;
            // tile group
            const int ntiles = tiles.cols * tiles.rows;
            if (ntiles > 1) {
                NEED(br.f(1) == 0, "tile_start_and_end_present_flag not supported");
                br.byte_align();
            }
            size_t tpos = br.pos >> 3;
            for (int tn = 0; tn < ntiles; tn++) {
                size_t tsz;
                if (tn == ntiles - 1) tsz = (size_t)sz - tpos;
                else {
                    tsz = 0;
                    for (int k = 0; k < tiles.tileSizeBytes; k++) tsz |= (size_t)p[tpos + k] << (8 * k);
                    tsz += 1;
                    tpos += tiles.tileSizeBytes;
                }
                NEED(tpos + tsz <= sz, "tile beyond OBU");
                DecSink ds(p + tpos, tsz);
                encode_tile(ds, tn / tiles.cols, tn % tiles.cols);
                PS->tile_bytes.push_back((uint32_t)tsz);
                PS->tile_offsets.push_back((uint64_t)(p - obus) + tpos);
                tpos += tsz;
            }
            done = true;
        }
        pos += (size_t)sz;
    }
    NEED(done, "no frame found");
    PS->block_txb.push_back((uint32_t)PS->txb.size());
    R->n_blocks = (uint32_t)PS->blocks.size();
    R->n_txb = (uint32_t)PS->txb.size();
    R->n_coeffs = PS->coeffs.size();
    R->blocks = PS->blocks.data();
    R->block_txb = PS->block_txb.data();
    R->txb = PS->txb.data();
    R->coeffs = PS->coeffs.data();
    PS->seq_level_idx = sq.level;
}

}  // namespace av1g

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------
using namespace av1g;

extern "C" int av1g_tile_layout(uint32_t width, uint32_t height, int cols_log2, int rows_log2, av1g_tiles *out) {
    TileInfo t;
    if (width < 1 || height < 1 || !compute_tiles(width, height, cols_log2, rows_log2, t)) return AV1G_ERR_INVALID;
    out->cols_log2 = t.colsLog2;
    out->rows_log2 = t.rowsLog2;
    out->cols = t.cols;
    out->rows = t.rows;
    for (uint32_t i = 0; i <= t.cols; i++) out->mi_col_starts[i] = t.miColStarts[i];
    for (uint32_t i = 0; i <= t.rows; i++) out->mi_row_starts[i] = t.miRowStarts[i];
    return AV1G_OK;
}

extern "C" void av1g_legalize_sb_qindex(int base_q_idx, int delta_q_res, const uint8_t *target, size_t n, uint8_t *legal) {
    const int step = 1 << (delta_q_res & 3);
    for (size_t i = 0; i < n; i++) {
        const int d = (int)target[i] - base_q_idx;
        int k = d >= 0 ? (d + step / 2) / step : -((-d + step / 2) / step);  // nearest multiple of step
        int v = base_q_idx + k * step;
        while (v < 1) v += step;
        while (v > 255) v -= step;
        legal[i] = (uint8_t)v;
    }
}

extern "C" int av1g_postfilter(const av1g_decision_record *rec, uint8_t *const planes[3], const int stride[3]) {
    if (!rec || !planes || !stride) return AV1G_ERR_INVALID;
    av1g_pf_frame f;
    memset(&f, 0, sizeof f);
    av1g_pf_frame_init(&rec->fp, &f);
    const size_t nmi = (size_t)f.MiRows * f.MiCols, nuv = (size_t)(f.MiRows >> 1) * (f.MiCols >> 1);
    std::vector<uint8_t> skip(nmi, 0), txY(nmi, 0), txU(nuv, 0), txV(nuv, 0);
    std::vector<int8_t> cdef((size_t)f.sbCols * f.sbRows, -1);
    f.skip = skip.data();
    f.lfTx[0] = txY.data();
    f.lfTx[1] = txU.data();
    f.lfTx[2] = txV.data();
    f.cdefIdx = cdef.data();
    for (uint32_t b = 0; b < rec->n_blocks; b++) av1g_pf_mark_block(&f, &rec->blocks[b]);
    for (int p = 0; p < (f.mono ? 1 : 3); p++) { f.plane[p] = planes[p]; f.stride[p] = stride[p]; }
    av1g_deblock_frame(&f);
    if (!f.enableCdef) return AV1G_OK;
    std::vector<uint8_t> out[3];
    uint8_t *dst[3] = {nullptr, nullptr, nullptr};
    for (int p = 0; p < (f.mono ? 1 : 3); p++) {
        const int h = (f.MiRows * 4) >> (p ? 1 : 0);
        out[p].assign((size_t)h * stride[p], 0);
        dst[p] = out[p].data();
    }
    av1g_cdef_frame(&f, dst, stride);
    for (int p = 0; p < (f.mono ? 1 : 3); p++) {
        const int h = (f.MiRows * 4) >> (p ? 1 : 0), w = (f.MiCols * 4) >> (p ? 1 : 0);
        for (int y = 0; y < h; y++) memcpy(planes[p] + (size_t)y * stride[p], dst[p] + (size_t)y * stride[p], (size_t)w);
    }
    return AV1G_OK;
}

int av1g_apply_sb_qindex(av1g_decision_record *rec, const uint8_t *sb_map) {
    const int sbCols = (av1g_mi_cols(rec->fp.width) + 15) >> 4;
    for (uint32_t b = 0; b < rec->n_blocks; b++) {
        av1g_block &k = rec->blocks[b];
        k.sb_qindex = sb_map[(size_t)(k.mi_row >> 4) * sbCols + (k.mi_col >> 4)];
    }
    return AV1G_OK;
}

extern "C" int av1g_layout(av1g_decision_record *rec, uint32_t txb_cap, uint64_t coeff_cap) {
    const av1g_frame_params &fp = rec->fp;
    const int MiCols = av1g_mi_cols(fp.width), MiRows = av1g_mi_rows(fp.height);
    const bool fill = rec->txb && rec->block_txb;
    uint32_t n = 0;
    uint64_t nc = 0;
    // pass 1: counts
    for (uint32_t b = 0; b < rec->n_blocks; b++) {
        const av1g_block &k = rec->blocks[b];
        if (k.bsize >= AV1G_BLOCK_SIZES || k.mi_row >= MiRows || k.mi_col >= MiCols) return AV1G_ERR_INVALID;
        int depth = k.tx_depth > av1g_max_tx_depth(k.bsize) ? av1g_max_tx_depth(k.bsize) : k.tx_depth;
        av1g_for_each_txb(k.bsize, k.mi_row, k.mi_col, depth, fp.monochrome, MiRows, MiCols,
                          [&](int, int txSz, int, int, int, int) { n++; nc += av1g_tx_coeffs(txSz); });
    }
    rec->n_txb = n;
    rec->n_coeffs = nc;
    if (!fill || txb_cap < n || coeff_cap < nc) return AV1G_ERR_CAPACITY;
    n = 0;
    nc = 0;
    for (uint32_t b = 0; b < rec->n_blocks; b++) {
        const av1g_block &k = rec->blocks[b];
        rec->block_txb[b] = n;
        int depth = k.tx_depth > av1g_max_tx_depth(k.bsize) ? av1g_max_tx_depth(k.bsize) : k.tx_depth;
        av1g_for_each_txb(k.bsize, k.mi_row, k.mi_col, depth, fp.monochrome, MiRows, MiCols,
                          [&](int plane, int txSz, int x4, int y4, int, int) {
                              av1g_txb &t = rec->txb[n++];
                              t.coeff_off = (uint32_t)nc;
                              t.x4 = (uint16_t)x4;
                              t.y4 = (uint16_t)y4;
                              t.plane = (uint8_t)plane;
                              t.tx_size = (uint8_t)txSz;
                              t.tx_type = AV1G_DCT_DCT;
                              t.flags = 0;
                              t.eob = 0;
                              t.reserved = 0;
                              nc += av1g_tx_coeffs(txSz);
                          });
    }
    rec->block_txb[rec->n_blocks] = n;
    return AV1G_OK;
}

int av1g::encode_with_hook(av1g_decision_record *rec, const av1g_encode_opts *opts, av1g_output *out, TxbHook *hook,
                           std::vector<std::vector<uint32_t>> *tileSyms, const std::vector<TileSkip> *skip,
                           std::vector<std::vector<uint8_t>> *tilePayloads) {
    memset(out, 0, sizeof *out);
    av1g_encode_opts o = {0, -1};
    if (opts) o = *opts;
    try {
        Encoder enc(rec, o, hook);
        enc.tileSyms = tileSyms;
        enc.skipTiles = skip;
        enc.tilePayloadsOut = tilePayloads;
        enc.run(out);
        return AV1G_OK;
    } catch (const Error &e) {
        av1g_output_free(out);
        snprintf(out->error, sizeof out->error, "%s", e.msg);
        return e.code;
    } catch (const std::exception &e) {
        av1g_output_free(out);
        snprintf(out->error, sizeof out->error, "internal: %s", e.what());
        return AV1G_ERR_INTERNAL;
    }
}

int av1g::parse_obus(const uint8_t *obus, size_t n, ParseStore &ps, std::string &err) {
    ps = ParseStore();
    memset(&ps.rec, 0, sizeof ps.rec);
    try {
        Encoder enc(&ps);
        enc.parse(obus, n);
        return AV1G_OK;
    } catch (const Error &e) {
        err = e.msg;
        return e.code;
    } catch (const std::exception &e) {
        err = std::string("internal: ") + e.what();
        return AV1G_ERR_INTERNAL;
    }
}

extern "C" int av1g_encode(av1g_decision_record *rec, const av1g_encode_opts *opts, av1g_output *out) {
    return encode_with_hook(rec, opts, out, nullptr);
}

extern "C" int av1g_validate(const av1g_decision_record *rec, char *err, size_t errlen) {
    av1g_output out;
    av1g_encode_opts o = {AV1G_ENC_SKIP_RECON | AV1G_ENC_NO_RECON, -1};
    int rc = av1g_encode(const_cast<av1g_decision_record *>(rec), &o, &out);
    if (rc != AV1G_OK && err && errlen) snprintf(err, errlen, "%s", out.error);
    av1g_output_free(&out);
    return rc;
}

extern "C" void av1g_output_free(av1g_output *out) {
    free(out->obu);
    free(out->avif);
    for (int p = 0; p < 3; p++) free(out->recon[p]);
    out->obu = out->avif = nullptr;
    out->recon[0] = out->recon[1] = out->recon[2] = nullptr;
    out->obu_size = out->avif_size = 0;
}

struct av1g_parsed_priv { ParseStore ps; };

extern "C" int av1g_parse(const uint8_t *obus, size_t size, av1g_parsed **out) {
    av1g_parsed *p = (av1g_parsed *)calloc(1, sizeof(av1g_parsed));
    av1g_parsed_priv *pr = new av1g_parsed_priv();
    p->priv = pr;
    std::string err;
    int rc = parse_obus(obus, size, pr->ps, err);
    p->rec = pr->ps.rec;
    p->seq_level_idx = pr->ps.seq_level_idx;
    p->n_tiles = (uint32_t)pr->ps.tile_bytes.size();
    p->tile_bytes = pr->ps.tile_bytes.empty() ? nullptr : pr->ps.tile_bytes.data();
    p->tile_offsets = pr->ps.tile_offsets.empty() ? nullptr : pr->ps.tile_offsets.data();
    snprintf(p->error, sizeof p->error, "%s", err.c_str());
    *out = p;
    return rc;
}

extern "C" void av1g_parsed_free(av1g_parsed *p) {
    if (!p) return;
    delete (av1g_parsed_priv *)p->priv;
    free(p);
}
