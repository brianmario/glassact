// GlassActCodec — xxHash64, RAW/LZ4/LZBITMAP/VP8L tile codecs, arenas (§3.4, §4.5).
// Hot-path codec module. Builds at plain -O: -Ounchecked gains nothing
// measurable and would strip TileOps.apply's bounds checks (§8.4, BENCHMARKS
// "-Ounchecked on GlassActCodec"). Wire parsing lives in GlassActWire (INV-6).
