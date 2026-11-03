// AVIF (ISOBMFF) writer: a byte-exact C++ port of
// avif_conversion/hybrid_nvenc_libavif/avif_muxer.py:mux_avif() for still images.
// av1C is derived from the sequence header OBU contained in the stream.
#include "av1g/av1g.h"

#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

typedef std::vector<uint8_t> Bytes;

void be32(Bytes &b, uint32_t v) { for (int i = 3; i >= 0; i--) b.push_back((uint8_t)(v >> (8 * i))); }
void be16(Bytes &b, uint32_t v) { b.push_back((uint8_t)(v >> 8)); b.push_back((uint8_t)v); }
void app(Bytes &b, const Bytes &x) { b.insert(b.end(), x.begin(), x.end()); }
void app(Bytes &b, const char *s, size_t n) { b.insert(b.end(), s, s + n); }

Bytes box(const char *type, const Bytes &data) {
    Bytes b;
    be32(b, (uint32_t)(8 + data.size()));
    app(b, type, 4);
    app(b, data);
    return b;
}
Bytes fullbox(const char *type, int version, uint32_t flags, const Bytes &data) {
    Bytes b;
    be32(b, (uint32_t)(12 + data.size()));
    app(b, type, 4);
    be32(b, ((uint32_t)version << 24) | (flags & 0xFFFFFF));
    app(b, data);
    return b;
}

struct BitReader {
    const uint8_t *d; size_t n; size_t pos = 0;
    BitReader(const uint8_t *d_, size_t n_) : d(d_), n(n_) {}
    uint32_t get(int k) {
        uint32_t v = 0;
        for (int i = 0; i < k; i++, pos++) {
            if ((pos >> 3) >= n) return v;
            v = (v << 1) | ((d[pos >> 3] >> (7 - (pos & 7))) & 1);
        }
        return v;
    }
};

struct Cfg { int profile = 0, level = 0, tier = 0, hbd = 0, twelve = 0, mono = 0, ssx = 1, ssy = 1, csp = 0; };

bool read_leb128(const uint8_t *p, size_t n, size_t &pos, uint64_t &v) {
    v = 0;
    for (int i = 0; i < 8; i++) {
        if (pos >= n) return false;
        uint8_t b = p[pos++];
        v |= (uint64_t)(b & 0x7f) << (7 * i);
        if (!(b & 0x80)) return true;
    }
    return true;
}

bool parse_seq(const uint8_t *obus, size_t n, Cfg &c) {
    size_t pos = 0;
    while (pos < n) {
        uint8_t h = obus[pos++];
        int type = (h >> 3) & 15, ext = (h >> 2) & 1, has_size = (h >> 1) & 1;
        if (ext) pos++;
        uint64_t sz = n - pos;
        if (has_size && !read_leb128(obus, n, pos, sz)) return false;
        if (pos + sz > n) return false;
        if (type == 1) {
            BitReader br(obus + pos, (size_t)sz);
            c.profile = br.get(3);
            br.get(1);  // still_picture
            if (!br.get(1)) return false;  // only reduced_still_picture_header streams
            c.level = br.get(5);
            int wb = br.get(4) + 1, hb = br.get(4) + 1;
            br.get(wb); br.get(hb);
            br.get(1); br.get(1); br.get(1);  // 128 sb, filter intra, edge filter
            br.get(1); br.get(1); br.get(1);  // superres, cdef, restoration
            c.hbd = br.get(1);
            if (c.profile == 2 && c.hbd) c.twelve = br.get(1);
            c.mono = c.profile == 1 ? 0 : br.get(1);
            int cp = 2, tc = 2, mc = 2;
            if (br.get(1)) { cp = br.get(8); tc = br.get(8); mc = br.get(8); }
            if (c.mono) { c.ssx = c.ssy = 1; c.csp = 0; }
            else if (cp == 1 && tc == 13 && mc == 0) { c.ssx = c.ssy = 0; c.csp = 0; }
            else {
                br.get(1);  // color_range
                if (c.profile == 0) { c.ssx = c.ssy = 1; }
                else if (c.profile == 1) { c.ssx = c.ssy = 0; }
                else { c.ssx = 1; c.ssy = 0; }
                c.csp = (c.ssx && c.ssy) ? br.get(2) : 0;
            }
            return true;
        }
        pos += (size_t)sz;
    }
    return false;
}

}  // namespace

extern "C" void av1g_exif_orientation_to_irot_imir(int orientation, int32_t *irot, int32_t *imir) {
    *irot = -1;
    *imir = -1;
    switch (orientation) {
    case 2: *imir = 1; break;
    case 3: *irot = 2; break;
    case 4: *imir = 0; break;
    case 5: *irot = 1; *imir = 0; break;
    case 6: *irot = 3; break;
    case 7: *irot = 3; *imir = 0; break;
    case 8: *irot = 1; break;
    default: break;  // 1 = identity, others reserved
    }
}

extern "C" int av1g_mux_avif(const uint8_t *obus, size_t obu_size, uint32_t width, uint32_t height,
                             uint8_t **avif, size_t *avif_size) {
    return av1g_mux_avif_ex(obus, obu_size, width, height, nullptr, avif, avif_size);
}

extern "C" int av1g_mux_avif_ex(const uint8_t *obus, size_t obu_size, uint32_t width, uint32_t height,
                                const av1g_avif_meta *md, uint8_t **avif, size_t *avif_size) {
    Cfg cfg;
    if (!parse_seq(obus, obu_size, cfg)) return AV1G_ERR_INVALID;
    Bytes hdlr_d = {0, 0, 0, 0};
    app(hdlr_d, "pict", 4);
    hdlr_d.resize(hdlr_d.size() + 12, 0);
    hdlr_d.push_back(0);
    Bytes hdlr = fullbox("hdlr", 0, 0, hdlr_d);
    Bytes pitm_d; be16(pitm_d, 1);
    Bytes pitm = fullbox("pitm", 0, 0, pitm_d);
    Bytes ispe_d; be32(ispe_d, width); be32(ispe_d, height);
    Bytes ispe = fullbox("ispe", 0, 0, ispe_d);
    Bytes av1c_d = {0x81, (uint8_t)(((cfg.profile & 7) << 5) | (cfg.level & 31)),
                    (uint8_t)(((cfg.tier & 1) << 7) | ((cfg.hbd & 1) << 6) | ((cfg.twelve & 1) << 5) |
                              ((cfg.mono & 1) << 4) | ((cfg.ssx & 1) << 3) | ((cfg.ssy & 1) << 2) | (cfg.csp & 3)),
                    0x00};
    Bytes av1c = box("av1C", av1c_d);
    Bytes pixi_d;
    if (cfg.mono) { pixi_d.push_back(1); pixi_d.push_back(8); }
    else { pixi_d.push_back(3); pixi_d.push_back(8); pixi_d.push_back(8); pixi_d.push_back(8); }
    Bytes pixi = fullbox("pixi", 0, 0, pixi_d);
    Bytes colr_d;
    app(colr_d, "nclx", 4);
    be16(colr_d, 1); be16(colr_d, 13); be16(colr_d, 6);  // BT.709 primaries, sRGB TC, BT.601 matrix
    colr_d.push_back(0x80);                                 // full range
    Bytes colr = box("colr", colr_d);
    // property order: ispe, av1C, pixi, [colr prof], colr nclx, [irot], [imir]
    // (descriptive before transformative; irot before imir as in libavif)
    Bytes ipco_d; app(ipco_d, ispe); app(ipco_d, av1c); app(ipco_d, pixi);
    std::vector<uint8_t> assoc = {0x81, 0x82, 0x03};  // essential bit | 1-based index
    int idx = 3;
    if (md && md->icc && md->icc_size) {
        Bytes prof_d;
        app(prof_d, "prof", 4);
        prof_d.insert(prof_d.end(), md->icc, md->icc + md->icc_size);
        app(ipco_d, box("colr", prof_d));
        assoc.push_back((uint8_t)++idx);
    }
    app(ipco_d, colr);
    assoc.push_back((uint8_t)++idx);
    if (md && md->irot >= 0) {
        app(ipco_d, box("irot", Bytes{(uint8_t)(md->irot & 3)}));
        assoc.push_back((uint8_t)(0x80 | ++idx));
    }
    if (md && md->imir >= 0) {
        app(ipco_d, box("imir", Bytes{(uint8_t)(md->imir ? 1 : 0)}));
        assoc.push_back((uint8_t)(0x80 | ++idx));
    }
    Bytes ipco = box("ipco", ipco_d);
    Bytes ipma_d; be32(ipma_d, 1); be16(ipma_d, 1); ipma_d.push_back((uint8_t)assoc.size());
    app(ipma_d, assoc);
    Bytes ipma = fullbox("ipma", 0, 0, ipma_d);
    Bytes iprp_d; app(iprp_d, ipco); app(iprp_d, ipma);
    Bytes iprp = box("iprp", iprp_d);
    Bytes infe_d; be16(infe_d, 1); be16(infe_d, 0); app(infe_d, "av01", 4); infe_d.push_back(0);
    Bytes infe = fullbox("infe", 2, 0, infe_d);
    Bytes iinf_d; be16(iinf_d, 1); app(iinf_d, infe);
    Bytes iinf = fullbox("iinf", 0, 0, iinf_d);
    Bytes ftyp_d; app(ftyp_d, "avif", 4); be32(ftyp_d, 0); app(ftyp_d, "avifmif1", 8);
    Bytes ftyp = box("ftyp", ftyp_d);
    auto iloc = [&](uint32_t off) {
        Bytes d = {0x44, 0x00};
        be16(d, 1); be16(d, 1); be16(d, 0); be16(d, 1);
        be32(d, off); be32(d, (uint32_t)obu_size);
        return fullbox("iloc", 0, 0, d);
    };
    Bytes meta_d1; app(meta_d1, hdlr); app(meta_d1, pitm); app(meta_d1, iinf); app(meta_d1, iloc(0)); app(meta_d1, iprp);
    Bytes meta1 = fullbox("meta", 0, 0, meta_d1);
    uint32_t off = (uint32_t)(ftyp.size() + meta1.size() + 8);
    Bytes meta_d; app(meta_d, hdlr); app(meta_d, pitm); app(meta_d, iinf); app(meta_d, iloc(off)); app(meta_d, iprp);
    Bytes meta = fullbox("meta", 0, 0, meta_d);
    Bytes file;
    app(file, ftyp);
    app(file, meta);
    be32(file, (uint32_t)(8 + obu_size));
    app(file, "mdat", 4);
    file.insert(file.end(), obus, obus + obu_size);
    *avif = (uint8_t *)malloc(file.size());
    memcpy(*avif, file.data(), file.size());
    *avif_size = file.size();
    return AV1G_OK;
}
