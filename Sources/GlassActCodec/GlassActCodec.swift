// GlassActCodec — xxHash64, RAW/LZ4/LZBITMAP/VP8L tile codecs, arenas (§3.4, §4.5).
// Hot-path codec module. Builds at plain -O (the §8.4 -Ounchecked flag was
// measured to gain nothing — BENCHMARKS.md, 2026-09-26). Wire parsing still
// lives in GlassActWire (INV-6).
