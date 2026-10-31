// av1core internal helpers (not part of the public API)
#ifndef AV1G_INTERNAL_H
#define AV1G_INTERNAL_H

#include <cstdarg>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>
#include "av1g/av1g.h"

#define AV1G_ENC_SKIP_RECON AV1G_ENC_BITSTREAM_ONLY  /* symbol coding only (validation) */
#define AV1G_ENC_CHECK_EDGES 0x20000u /* internal: cross-check av1g_txb_edges() against BlockDecoded */

namespace av1g {

struct Error : std::runtime_error {
    int code;
    char msg[256];
    Error(int c, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
};

struct BitWriter {
    std::vector<uint8_t> buf;
    uint64_t pos = 0;
    void bit(int b) {
        if ((pos & 7) == 0) buf.push_back(0);
        if (b) buf.back() |= (uint8_t)(0x80 >> (pos & 7));
        pos++;
    }
    void put(uint32_t v, int n) { for (int i = n - 1; i >= 0; i--) bit((v >> i) & 1); }
    void su(int v, int n) { put((uint32_t)v & ((1u << n) - 1), n); }
    void byte_align() { while (pos & 7) bit(0); }
    void trailing_bits() { bit(1); byte_align(); }
};

inline void put_leb128(std::vector<uint8_t> &o, uint64_t v) {
    do {
        uint8_t b = v & 0x7f;
        v >>= 7;
        if (v) b |= 0x80;
        o.push_back(b);
    } while (v);
}

struct TileInfo {
    int colsLog2 = 0, rowsLog2 = 0;
    uint32_t cols = 1, rows = 1;
    int minLog2TileCols = 0, maxLog2TileCols = 0, maxLog2TileRows = 0, minLog2Tiles = 0, minLog2TileRows = 0;
    uint32_t miColStarts[65], miRowStarts[65];
    int tileSizeBytes = 4;
};

bool compute_tiles(uint32_t W, uint32_t H, int colsLog2, int rowsLog2, TileInfo &t);

// Closed-loop hook: called for every coded tx block of a non-skip block after its
// exact prediction has been written to the reconstruction buffer and before the
// coefficients are range-checked and coded.  The hook may overwrite the tx block's
// coefficients and (luma only) t.tx_type.  Used by the CPU reference engine.
struct TxbHook {
    virtual ~TxbHook() {}
    // qmLevel: quantizer-matrix level of this plane (15 = none); weights for a tx type
    // are av1g_qm(1, qmLevel, plane, txSz, txType)
    virtual void on_txb(const av1g_block &b, uint32_t blockIdx, av1g_txb &t, int16_t *coeffs,
                        const uint8_t *recon, int reconStride, int dcQ, int acQ, int derivedTxType, int qmLevel) = 0;
};

// parse mode storage (record + the vectors it points into)
struct ParseStore {
    av1g_decision_record rec;
    std::vector<av1g_block> blocks;
    std::vector<uint32_t> block_txb;
    std::vector<av1g_txb> txb;
    std::vector<int16_t> coeffs;
    std::vector<uint32_t> tile_bytes;
    std::vector<uint64_t> tile_offsets;  // offset of each tile payload in the parsed buffer
    int seq_level_idx = 0;
};
int parse_obus(const uint8_t *obus, size_t n, ParseStore &ps, std::string &err);

int encode_with_hook(av1g_decision_record *rec, const av1g_encode_opts *opts, av1g_output *out, TxbHook *hook,
                     std::vector<std::vector<uint32_t>> *tileSyms = nullptr);

}  // namespace av1g
#endif
