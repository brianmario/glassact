# Glass Act — Design

How Glass Act works, as built. Code comments cite this document by section
(`§3.5`, `§8.8`…), so **keep the section numbers stable**: add new
subsections rather than renumbering. When the code and this document
disagree, the code wins. Fix this document in the same change.

Measurements and the reasons for each choice live in
[`BENCHMARKS.md`](../BENCHMARKS.md), which this document points into by
section title. Open work is in GitHub issues.

---

## 0. What this is

Glass Act is a **state-synchronization system, not a video streamer**:
- The Host has the real screen. The Viewer holds a replica, the **canvas**: a grid
  of 64×64 tiles, each a last-writer-wins register stamped with the sequence
  number that wrote it.
- Static and text content travels as **absolute, lossless tile records** in
  datagrams small enough to survive a lossy network. Records may arrive late,
  out of order, duplicated or never, and the canvas still converges.
- Loss is repaired by **re-encoding the current content**, never by
  retransmitting stale pixels.
- Motion-heavy content (scrolling pages, video, window drags) is sent as
  **hardware HEVC** on a separate reliable stream and drawn as an **overlay**
  above the canvas. Each tile hands back to lossless records once it goes still.
  The overlay never writes into the canvas.

There are no keyframes or timestamps in the scheduling sense, and no
container. QUIC provides the framing, and the compositor provides the clock.

---

## 1. Invariants

These are frozen. Each one has a named `INV_*` test, and a failing invariant
test blocks merge. Several carry extensions, spelled out here, so the rule
a test checks is the rule in this document.

- **INV-1 Absolute or pinned payloads.** No tile record depends on
  *unspecified* prior content:
  - RAW, LZ4, LZBITMAP and WEBPL fully define the tile.
  - DELTA (0x0B) and CACHE REF (0x07) do refer to earlier content, but only to
    content that was ACK-confirmed. They also carry a hash of it, and the viewer
    refuses (and NACKs) on a mismatch (§4.8).
  - HEVC video predicts across frames, but it sits outside the canvas (§4.6).
- **INV-2 Per-tile LWW.** The viewer stores a `seq` per tile. A record applies
  iff its `frame_seq` is `newer` (§3.6) than the tile's seq. Batches are never
  dropped whole; the check is per tile. Extensions:
  - Reassembled fragments are re-checked against LWW when they complete.
  - Video stamps are LWW-gated but don't advance `tileSeq`, so a record with
    the same seq wins the tie.
  - Cache slots are LWW by seq of their own; a STORE stores even when its
    apply loses LWW.
- **INV-3 ACK-gated references.** The encoder only predicts from state the
  viewer has ACKed: the shadow map, DELTA bases, scroll sources and cache REF
  targets all require the tile to be settled (ACKed, nothing in flight).
  - The one exception is scroll promotion. It is speculative, and the
    SCROLL_ACK digest verifies it afterwards (§4.8).
- **INV-4 Newest wins, never queue.** With ≥ 2 batches open, or the pacer
  holding > 20 ms of data, the host skips the capture.
  - The skipped capture's dirty rects carry forward (`missedDirty`), so the
    damage still qualifies next tick.
  - The same rule appears elsewhere: video frames are submitted newest-wins,
    and a deferred tile is never queued; it re-qualifies against the current
    frame.
- **INV-5 Reliability is for state, not pixels.** Tile records ride datagrams
  and are never retransmitted. Reliable streams carry control (including
  SCROLL) and the video stream (HEVC, keyframes, lossy first paints), whose
  content is superseded rather than repaired.
  - A timed-out tile goes **cold** (`ackedHash = 0`) and is repainted from the
    current capture.
- **INV-6 Parser safety.** Every wire parse uses checked reads. Malformed
  input never crashes, over-reads or allocates without bound. Datagrams,
  control, video, claims, window lists, cache and DELTA payloads are all
  fuzzed.
  - Past the parser, the vendored libwebp decoders are fuzzed too, with
    mutated real WEBPL tiles and striped keyframes. A decode either fails
    or fills exactly the expected rect, and never writes outside it.
- **INV-7 No allocation / no ARC in per-frame tile paths** (§8). These
  exceptions are known and documented:
  - libwebp allocates when it encodes.
  - Region and keyframe buffers are allocated when they form.
  - One `Data` is created per datagram, and per control frame, at the
    transport boundary.
- **INV-8 Canvas is exactly-as-coded.** Nothing filters the canvas. Video and
  the cursor composite at present time from separate buffers.
  - Transient lossy paints (the cold-start first paint) do write
    the canvas. They write it as coded, never advance `tileSeq`, and are
    always overwritten by lossless records.
- **INV-9 One in-flight slot per tile.** A tile is in flight in at most one
  send. Re-sending overwrites the slot (`TileLedger`), and stale ACKs or
  timeouts for older sends are ignored.
  - Keyframes take slots. SCROLL clears the slots in its rect. A DELTA_NACK
    clears the slot under the seq guard.
- **INV-10 Idle = zero bytes.** No change → no tile datagrams. The traffic that
  remains on an idle session:
  - PING at 1 Hz and the viewer's 100 ms re-ACK of the newest batch;
  - a single re-sharpen sync frame when a video region goes quiet;
  - QUIC's own keepalive.

**Tests** (`Tests/CoreTests/InvariantTests.swift` unless noted):
- `INV_1_absolutePayloads`, `INV_1_absolutePayloads_parallelHashPath`
- `INV_2_perTileLWW`
- `INV_3_ackGatedReferences`
- `INV_4_newestWinsNeverQueue`, `INV_4_droppedCaptureDamageStillRequalifies`
- `INV_5_reliabilityForStateNotPixels`
- `INV_6_parserSafetyEngineLevel`, plus `INV_6_mutatedRealPayloadsNeverCrashTheViewer`
  in `EngineFuzzTests.swift`, the `INV_6_mutated*` decoder fuzz in
  `Tests/CodecTests/WebPDecodeFuzzTests.swift` and
  `INV_6_mutatedStripedKeyframesApplyExactlyOrDropCleanly` in
  `KeyframeDecodeFuzzTests.swift` (100× iterations under `just test-exhaustive`)
- `INV_7_noPerFrameArenaGrowth`
- `INV_8_canvasExactlyAsCoded`
- `INV_9_oneInflightSlotPerTile`, plus `INV_9_staleAckAndStaleTimeoutAreIgnored`
  in `TileLedgerTests.swift`
- `INV_10_idleZeroBytes`

---

## 2. Architecture

```
HOST                                          VIEWER
ScreenCaptureKit                              present (CALayer + IOSurface flip pool)
   │ CMSampleBuffer + dirtyRects                 ▲ display link; main only flips
   ▼                                             │
latest-frame slot (newest wins)               blit: canvas ⊕ video overlay ⊕ cursor
   ▼ encodeQueue (.userInteractive)              ▲ applyQueue (.userInteractive)
hash vs shadow → qualify → governor           Canvas (BGRA + per-tile seq)
   ├─ tile encode (RAW/LZ4/LZBITMAP/VP8L/       ▲          ▲            ▲
   │   DELTA/CACHE) → pack ── QUIC datagrams ───┘          │            │
   ├─ SCROLL ─────────────── QUIC control ──────────────────┘            │
   └─ video region (VT HEVC) / keyframes ── QUIC video stream ── overlay ┘
TileLedger / batches ◄────── QUIC control ─── ACK, NACKs, SCROLL_ACK, PONG
```

**Concurrency** (§8.8):
- `HostEngine` and `ViewerEngine` are plain `final class`es, confined to their
  serial queues and marked `@unchecked Sendable`, with a doc comment that names
  the queue.
- **No actors or async/await in the capture→present pixel path.**
- Parallel work inside a tick (hashing, per-tile encode, VP8L stripes) fans out
  with `DispatchQueue.concurrentPerform` over disjoint per-tile writes, and the
  tick stays synchronous.
- Actors are fine in the control plane: apps, sessions, the agent driver.

**Modules** (§9):
- `GlassActWire` (bytes) → `GlassActCodec` (tile codecs, hash) →
  `GlassActCore` (engines) → `GlassActTransport` (QUIC, identity) →
  `GlassActSession` (viewer session, agents).
- The apps are thin shells over these modules.

---

## 3. Wire format (`WireVersion.current = 4`)

- All integers are little-endian.
- `varint` = unsigned LEB128, ≤ 4 bytes, so values are < 2²⁸. The reader accepts
  overlong encodings that are in range; the writer is canonical and traps
  out of range.
- Version compatibility is an **exact match**: the datagram header nibble,
  HELLO and HELLO_OK are all checked. Features are negotiated with caps bits
  (§3.8), not version bumps.
- Until 1.0 any release may change the wire (§12): bump the version and
  keep no old decode paths; both ends run the same build.

### 3.1 Geometry

- `tile = 64`, `cols = ceil(w/64)`, `rows = ceil(h/64)`,
  `tile_idx = row*cols + col` (u16). Width and height are 1…8192.
- Edge tiles crop: `tw = min(64, w − col*64)`, `th = min(64, h − row*64)`.
- RAW tile content is `th` rows × `tw*4` bytes of BGRA, tightly packed (no stride).
  This is also the canonical byte order for hashing (§4.5).
- Reference sizes:
  - 4K (3840×2160) is 60×34 = 2040 tiles.
  - 5K (5120×2880, the usual dev geometry) is 3600 tiles.
  - A full RAW tile is 16,384 B.

### 3.2 Pixel format

`pixfmt = 1`: BGRA8, sRGB. Values 2 (RGB10A2) and 3 (RGBA16F) are reserved.

### 3.3 Datagrams

**Header** (17 bytes):

| off | field | type | notes |
|---|---|---|---|
| 0 | ver_flags | u8 | high nibble = wire version; low nibble reserved (written 0, ignored) |
| 1 | frame_seq | u32 | batch id, increments per batch |
| 5 | dgram_idx | u16 | 0-based, `< dgram_cnt` |
| 7 | dgram_cnt | u16 | ≥ 1 |
| 9 | capture_ts_us | u64 | µs; telemetry only |

**Records**, repeated until the datagram ends:

`opcode u8 (≠0) | tile_idx u16 | frag_idx u8 | frag_cnt u8 (≥1, idx<cnt) | len varint | payload`

**Parsing:**
- The parse is atomic: the whole datagram is validated before any record is
  delivered, and a malformed datagram is dropped whole.
- Records never span datagrams.
- The viewer rejects any record payload over 16,400 B.

**Budget:**
- The budget is `min(max − 32, 1200)` and is re-read from
  `transport.maxDatagramSize` every tick. Below 1024 it is invalid.
- QUIC requests a 1400-byte datagram frame, so in practice the budget is 1200.
- A fragment carries at most `budget − 25` bytes of payload.

**Fragmentation:**
- A tile's logical payload is split into ≤ 255 fragments. The logical payload
  is the CACHE/DELTA prefix plus the body.
- A batch is ≤ 65,535 datagrams; the host stops admitting tiles 256 short of that.

**Reassembly** (`TileReassembler`):
- All-or-nothing per (tile, seq), one slot per tile.
- A newer seq replaces a partial. A `frag_cnt` mismatch rejects the tile.
- Duplicates are ignored. A partial expires after 250 ms. The total is bounded.

### 3.4 Tile opcodes

| op | name | payload |
|---|---|---|
| 0x01 | RAW | cropped BGRA (§3.1) |
| 0x02 | LZ4 | Apple Compression `COMPRESSION_LZ4` (framed) of RAW |
| 0x07 | CACHE | `sub=0 STORE_APPLY {slot u16, inner u8, inner…}`: apply, and store in `cache[slot]`; `sub=1 REF {slot u16, contentHash u64}` (11 B): tile := cache[slot] if its hash matches |
| 0x09 | LZBITMAP | `COMPRESSION_LZBITMAP` of RAW |
| 0x0A | WEBPL | VP8L lossless (vendored libwebp) of RAW |
| 0x0B | DELTA | `mode u8, baseHash u64, [x,y,w,h u8 if mode 1], inner u8, inner…`. Mode 0 = whole-tile XOR against the base; mode 1 = an absolute sub-rect. The viewer applies it only if its tile hashes to `baseHash`, else it NACKs |

- **Inner opcodes** (inside DELTA and CACHE STORE) are one of 0x01, 0x02, 0x09 or 0x0A.
- **Cache** has 4096 slots on each end. The host allocates slots.
- **Reserved, never reuse:** `0x03 COPY`, `0x04 PALETTE`, `0x05 DCT`,
  `0x06 REFINE`, `0x08 VIDEO_REGION`. Scroll is a control TLV (§3.5) and
  video has its own stream (§3.7).
- **Invalid:** `0x00`. Opcodes 0x0C+ are unassigned, and the viewer skips
  opcodes it doesn't know.
- **SKIP** is the absence of a record.

### 3.5 Control stream

**Framing:** reliable and ordered, as TLVs `{type u8, len varint, body}`.
- A body is at most 1 MiB and must be consumed exactly.
- Unknown types with a valid length are skipped.
- Any malformed frame latches the stream, and the connection is torn down.

| type | name | dir | body |
|---|---|---|---|
| 0x01 | HELLO | H→V | ver u8, w u16, h u16, tile u8, pixfmt u8, caps u32. The host speaks first; re-sent in-session on a geometry change |
| 0x02 | HELLO_OK | V→H | ver u8, caps u32, geoMode u8 (0–4), geoW u16, geoH u16, geoScale u8 |
| 0x03 | ACK | V→H | frameSeq u32, dgramCnt u16, bitmap[ceil(cnt/8)] (bit set = received) |
| 0x04 | PING | H→V | nonce u64, tUS u64 (the host also answers a PING) |
| 0x05 | PONG | V→H | nonce u64, tUS u64, recvTUS u64 |
| 0x06 | SCROLL | H→V | frameSeq u32, x, y, w, h u16, dx, dy i16 |
| 0x07 | SCROLL_ACK | V→H | frameSeq u32, cnt u16, skipped u16×cnt, digest u64 |
| 0x08 | PAUSE_HINT | V→H | paused u8 (0 resume, 1 pause; §4.10) |
| 0x09 | KEYFRAME_ACK | V→H | seq u32 |
| 0x0A | DELTA_NACK | V→H | frameSeq u32, cnt u16, tiles u16×cnt. Also used for any received-but-unapplied record (§5) |
| 0x0B | CURSOR_POS | H→V | x u16, y u16, visible u8 |
| 0x0C | CURSOR_IMAGE | H→V | w, h u16 (1–512), hotX, hotY u16, scale u8 (1–4), bgra |
| 0x0D | RESIZE | V→H | mode u8 (1, 2, 4), w u16, h u16, scale u8 |
| 0x0E | INPUT | V→H | kind u8, x u16, y u16, a i32, b i32 (§3.8) |
| 0x0F | CLIPBOARD | both | format u8 (1 = UTF-8), data |
| 0x10 | QUALITY | V→H | presentedScalePct u8, floor u8 (0 automatic, 1–3 keep high/medium/low), preferSharpness u8 (0–1) |
| 0x11 | WINDOW_LIST | H→V | count u16, then per window: id u32, app, title, thumbFmt u8, thumbW, thumbH u16, thumb |
| 0x12 | WINDOW_SELECT | V→H | windowID u32 (0 = full display) |
| 0x13 | WINDOW_CONTROL | V→H | action u8 (1 fullscreen, 2 resize, 3 end), w u16, h u16 |
| 0x14 | VIEWER_LOG | V→H | nameLen u8, name, offset u32, total u32 (≤ 16 MiB), data (≤ 64 KiB) |
| 0x15 | TEXT_INPUT | V→H | UTF-8, 1–4096 B |
| 0x16 | AGENT_STATE | V→H | active u8, len u8, label |
| 0x17 | UI_TREE_REQUEST | V→H | requestID u32, windowID u32, maxNodes u16 |
| 0x18 | UI_TREE | H→V | requestID u32, status u8, json |
| 0x19 | AGENT_SCOPE | H→V | control u8, len u8, reason |
| 0x1A | VIEWER_INFO | V→H | UTF-8 machine name, 1–64 B |
| 0x1B | SYNC_REQUEST | V→H | region u8, generation u32. The viewer can't decode that region and asks for a sync frame (§4.6, §5) |

**Cadence:**
- **ACKs:**
  - A completion ACK is sent when a batch completes.
  - A partial ACK is sent 8 ms after a batch's first datagram (with the same
    minimum gap between partials).
  - Every 100 ms the newest batch is re-ACKed as a keepalive. Every active
    incomplete batch is re-ACKed too, so the stragglers of an older open batch
    don't force a timeout.
  - The tracker has 4 slots, each expiring after 5 s.
  - NACKs precede their batch's ACK on the ordered stream.
- **PING/PONG:** the host PINGs at 1 Hz and keeps SRTT as an EWMA with α = 0.125.
- **Fast paths:** the hot frames (ACK, the NACKs, SCROLL_ACK, KEYFRAME_ACK and
  PONG) are built without allocating (`ControlFrames.swift`). They encode to
  the same bytes as `ControlMessage.encoded()`.

### 3.6 Sequence arithmetic

u32, wraparound-safe: `newer(a,b) := a != b && (a &- b) < 0x8000_0000`.
Every seq in the system uses this: batches, scrolls, keyframes, video stamps
and cache slots.

### 3.7 Video stream

The video stream is opened by the host inside the control QUIC group. It starts
with a single preamble byte `0x56` ('V'), then carries TLVs framed as in §3.5.
- A body is at most 8 MiB.
- A newer video stream replaces the old one (`onVideoReset`).

| type | name | body |
|---|---|---|
| 0x01 | START | region u8, generation u32, x, y, w, h u16, codec u8, cfgLen varint, config (hvcC) |
| 0x02 | FRAME | region u8, generation u32, seq u32, sync u8, captureUS u64, claimsMode u8, [claims], data |
| 0x03 | STOP | region u8, generation u32, reveal bitmap (may be empty) |
| 0x04 | KEYFRAME | seq u32, x, y, w, h u16, codec u8, stripeCount u8, stripes × (len varint, bytes) |
| 0x05 | REVEAL | region u8, generation u32, tile bitmap |

**Claims** say which tiles a frame changed:
- `claimsMode 0` means all tiles.
- `claimsMode 1` means runs: `n varint`, then n pairs of `(gap varint, count varint ≥ 1)`.
  The runs are region-relative and row-major over the region's tile box.

**Bitmaps** have one bit per tile over the session grid: bit t lives in
byte t/8, LSB first. Missing trailing bytes count as 0.

**Codec ids:**
- `VideoCodec`: 1 = HEVC. 2 (H.264) is reserved; 3 is reserved for AV1
  once hardware AV1 encode exists. 0x7E and 0x7F are mock codecs for tests.
- `KeyframeCodec`: 1 = striped VP8L (lossless), 2 = reserved (JXL),
  3 = striped WebP-lossy. Codec 3 is a transient paint: it never advances
  `tileSeq` and is never ACKed.

### 3.8 Capabilities and enums

**WireCaps** (u32): a capability is active only when both sides advertise it.

| bit | name | meaning |
|---|---|---|
| 0 | videoHEVC | HEVC video regions |
| 1 | videoAV1 | reserved for AV1 once hardware encode exists; today only the test rig's alternate mock codec (0x7E) |
| 2 | — | unassigned |
| 3 | — | unassigned |
| 4 | cursor | cursor as metadata (host stops burning it into pixels) |
| 5 | geometryFinal | this HELLO is final; don't request geometry again |
| 6 | windowList | single-window mode available |
| 7 | — | unassigned |
| 8 | — | unassigned |
| 9 | logUpload | host accepts VIEWER_LOG |
| 10 | virtualDisplay | geoMode 4 allowed |
| 11 | agentControl | TEXT_INPUT, AGENT_STATE, UI_TREE*, agent-flagged INPUT |

**Enums:**
- **INPUT kinds** (low 7 bits): 1 move, 2 down / 3 up (a = clicks, b = button),
  4 scroll in lines / 7 scroll in points (a = dx, b = dy), 5 keyDown / 6 keyUp
  (a = CGKeyCode, b = CGEventFlags).
  - Flag `0x80` marks agent-generated input, which the host runs through agent
    policy (§14).
  - Receivers ignore kinds they don't know.
- **GeometryMode:** 0 none, 1 client resolution, 2 scale, 3 native, 4 virtual
  display. RESIZE accepts only 1, 2 and 4.
- **UITreeStatus:** 0 ok, 1 notPermitted, 2 noWindow, 3 refused, 4 tooLarge.
- **WindowThumbFormat:** 0 none, 1 WebP-lossy, 2 AVIF.

### 3.9 Sign-in exchange

A viewer the host hasn't approved can sign in with the host Mac's account
(§13). This runs on its **own QUIC connection**, never inside a session:
- same port as the control tunnel, ALPN `glassact-signin`;
- the viewer presents its key as usual, and that key is what gets approved;
- one viewer-opened stream: one request, FIN, one response, close.

**Request** (≤ 1349 B; strict parse, exact consumption):

`ver u8 (1) | op u8 | userLen u8, user | passwordLen u16, password | deviceLen u8, device`

- `op`: 1 = query (how do new viewers get in? no credentials allowed),
  2 = sign in.
- UTF-8 throughout. Limits: user 255 B, password 1024 B, device 64 B.

**Response** (4 B): `ver u8 (1) | status u8 | retryAfterS u16`

| status | meaning |
|---|---|
| 1 signInAvailable | (query) new viewers sign in with this Mac's account |
| 2 askOnHost | the host's user approves new viewers by hand: dial and wait, comparing codes |
| 3 closed | not taking new viewers |
| 4 approved | this connection's key is approved (just now, or already) |
| 5 wrongCredentials | |
| 6 tooManyAttempts | try again in `retryAfterS` |

---

## 4. Host engine

### 4.1 Capture

- `SCStream` on the chosen display (or a single window, §4.10):
  - format: BGRA, sRGB, native pixel size;
  - `minimumFrameInterval = 1/60`, `queueDepth = 3`;
  - `showsCursor = false` when the `cursor` cap is active (CURSOR_POS/IMAGE
    instead), true otherwise.
- The callback holds the newest sample in a one-deep **latest slot**: newest
  replaces unprocessed older, which is the drop we want. It then signals
  `encodeQueue`. A replaced frame's dirty rects are merged in, not lost.
- Frames with no content (`.idle`, `.complete`) are skipped. `dirtyRects` are
  treated as hints.
- **`bytesPerRow` is padded, so every tile address is stride-aware.**

### 4.2 Tile bookkeeping (`TileLedger`)

Per tile, in a flat array: `ackedHash` (0 = unknown, or cold), `inflightHash`
and `inflightSeq`.

The ledger also holds:
- `pendingRepaint`: cold tiles owed a repaint;
- `carry`: warm tiles the governor deferred.

Each open batch records its seq, send time and per-datagram tile lists. A tile
commits only when *all* its datagrams are confirmed. The host also keeps an
**ACKed shadow canvas**: the pixels the viewer is known to have. Scroll
verification, DELTA bases and the cache all read it.

### 4.3 Encode tick (`HostEngine.encodeTick`)

**1. Gates**, in this order:
- resolve timeouts;
- a paused viewer (PAUSE_HINT, §4.10) stops here;
- **INV-4**: `openBatchCount < 2 && !pacerBacklogged`.

A skipped tick still has work to do:
- it stashes its dirty rects in `missedDirty`;
- an INV-4 skip with video negotiated still runs `videoSaturatedTick`, so
  regions keep streaming (a paused tick doesn't).

**2. Candidates:** this tick's dirty rects, plus missed damage, plus owed
tiles (repaint and carry). On the first tick after connect it is every tile.

**3. Cold start:**
- With video negotiated (§4.6) a full-screen region forms immediately, so the
  first picture is the HEVC sync frame.
- Otherwise (a video-less session, or the encoder refused to start) the host
  sends a lossy q90 first paint followed by a lossless striped VP8L keyframe
  (§4.7).

**4. Scroll detection** runs before the batch claims its seq (§4.8).

**5. Qualify:** `h = xxh64(tile)`. The tile is sent iff
`h != ackedHash && h != inflightHash`.
- Admission goes through the `SendGovernor` (§4.9) in two passes. Pass 0 takes
  fresh dirty tiles; pass 1 takes owed tiles, capped at 50 ms of the send rate.
- A rotor varies the starting tile from tick to tick.

**6. Per-tile codec choice** (`PayloadEncodeJob`, parallel; smallest wins):
- RAW, LZ4 and LZBITMAP are always tried.
- **VP8L** is tried only:
  - on ticks of ≤ 320 tiles (4096 while draining a settle);
  - and when the tile's position isn't in VP8L backoff. That backoff is a
    per-position memory of losses: 8 ticks, doubling up to 64.
  - Effort is 4 on ticks of ≤ 32 tiles and 1 above that.
- **DELTA** is tried only on settled tiles (§4.8), and it must strictly beat the
  best full-tile result.
- **CACHE** applies to full 64×64 tiles only:
  - a memcmp-verified hit sends an 11-byte REF, which beats everything;
  - otherwise a non-DELTA tile is wrapped in STORE_APPLY.

**7. Pack** (`DatagramPacker`) into the budgeted datagrams (§3.3), send the
whole batch with one `transport.sendDatagrams`, then
`ledger.markInflight(idx, h, seq)` (INV-9).

### 4.4 ACK and timeout resolution

**On an ACK for batch S:**
- For every tile whose datagrams are now all confirmed:
  `if inflightSeq == S { ackedHash = inflightHash; clear inflight }`. Otherwise
  the ACK is stale, from an overwritten send, and is ignored.
- Committing also copies the tile's retained pixels into the ACKed shadow.

**Timeout:**
- `max(3·SRTT, 50 ms) + serialization allowance`, floored at
  `min(2·ackDelay, 3 s)`.
- On timeout, each tile that still owns its slot goes **cold**: `ackedHash = 0`
  and it is queued for repaint.

  Clearing only the in-flight slot isn't enough: an un-ACKed tile can sit
  on stale content that the hash comparison would never see again (golden
  replay diverges).
- The timeout also releases cache pins and feeds `PaceController` and the
  governor's loss signal.

**No pixel retransmission, ever (INV-5).**

### 4.5 Hash

**xxHash64**, seed 0, over the tightly-packed cropped tile bytes (§3.1). It hashes
row by row straight from the strided capture buffer, with results identical
to hashing a tight copy.

Required tests:
- the known vector `xxh64("") == 0xEF46_DB37_51D8_E999`;
- determinism and avalanche;
- zero collisions across 10⁶ random 16 KB buffers (`just test-exhaustive`).

A collision costs one missed visual update, about 2⁻⁶⁴ per changed tile. It
never causes divergence. Cache hits and scroll moves are memcmp-verified, so
they don't rely on the hash.

Hashing fans out across cores at ≥ 128 candidates.

### 4.6 Video regions (`HostEngine+Video`, `VTVideo`, `VideoRegionTable`)

**The one mode: pinned full-screen HEVC, drawn as an overlay** (§5). Video
is on whenever both sides negotiate a codec. The Host's `GLASSACT_TILE_ONLY=1`
passes no encoder factory, so it offers no video caps and the session is
tiles only; headless agents (`video: false`) do the same from the viewer
side.

**Formation:**
- A full-screen region forms on the very first tick (the cold start, §4.3).
- After that it forms when both demand and genuinely churning candidates are
  ≥ 32 tiles, at least 3 ticks after a dissolve. *Churning* means the hash
  changed since the tile's last observation (`lastObservedHash`), not merely
  that it differs from `ackedHash`: a dissolve repaint's cold tiles stay
  un-ACKed for a round trip and must not re-form the region.
- INV-4-skipped ticks have no hashes and never form a region; neither do
  paused ticks (§4.10).
- Region edges are trimmed to even dimensions, because HEVC 4:2:0 needs them.

**Codecs:** the encoder factory is keyed by codec id. The host's preference
list is intersected with the viewer's caps, and the region starts on the
first negotiated codec whose encoder starts; START carries its id. Today
that is HEVC only. AV1 (codec 3, caps bit 1) is reserved for when hardware
AV1 encode exists.

**Lifecycle:**
- Each region is a *generation*. The viewer drops stragglers from older
  generations.
- A region dissolves:
  - after `regionQuietLimit` quiet ticks: 90, or 270 when it re-formed within
    120 ticks of the last dissolve (paging workloads). The wall-time limit
    scales the same way (2.1 s, 6.3 s). A frame touching fewer than 32 tiles
    counts as quiet, so typing returns to tiles;
  - after 30 empty encodes;
  - when a frame is too large for the wire;
  - when the video stream resets.
- While the viewer has paused content (§4.10) the region idles: nothing is
  encoded and it doesn't dissolve, so resuming continues it.

**Encoder** (`VTHEVCRegionEncoder`):
- Realtime, no B-frames, IDR only on demand, capture-time PTS.
- `MaxAllowedFrameQP = 34` is the quality floor.
- Bitrate is set by `VideoRateController` (§4.9). Quality levels 0–3 step it
  by about 0.66× each.

**Submission** (newest-wins): a frame is submitted only while the encoder has
fewer than 2 frames pending and the rate gate passes.
- A backlog skip with the encoder *not* full counts as bandwidth pressure. It
  steps the quality ladder: one level per 30-frame window if ≥ 1/3 of the
  window was pressured, and back after 4 healthy windows.
- The viewer's QUALITY message bounds the level: a downscaled presentation
  raises its minimum, and a quality floor of n (1–3) caps it at n.
- **Prefer sharpness** (QUALITY `preferSharpness` = 1):
  - Under pressure, the level holds and frame rate absorbs it instead: the
    send gate skips frames, newest wins.
  - With headroom, the frame-QP ceiling drops from 34 to
    `sharpMaxFrameQP` (28). It goes on after `sharpHealthyNeeded`
    pressure-free quality windows in a row (4 at first) and comes off at the
    first pressured window.
  - Each fall-back doubles the next wait, up to 64 windows, so a link that
    can't carry it settles at 34 instead of flapping.
  - A re-formed region starts under whichever ceiling is in effect, and
    turning the preference off restores 34 and the first wait.

**Overlay:**
- The viewer decodes into an overlay buffer, never into the canvas.
- On dissolve, STOP carries a **reveal bitmap**: tiles whose last frame hash
  equals `ackedHash` return to the canvas for free. The rest are repainted
  through the tile path.

**Per-tile handoff:**
- Frames carry claims (§3.7). A generation's first frame claims every tile.
- A claimed tile that has been still for 1 s hands back in one of two ways:
  - **REVEAL**, which is free when the canvas already holds its hash;
  - or a **lossless record** through the tile path, whose seq beats the claim
    stamp. This one is gated: no large update for 2 s, and a real change
    within the last 1 s.
- If a tile is re-claimed within 10 s, its backoff doubles.

**Re-sharpen:** a forced sync frame is sent once the region has been quiet for ≥ 1 s
and the last sync is ≥ 5 s old, provided either:
- the damage since that sync covers ≥ 1/10 of the region, or
- the bitrate cap has at least doubled.

**Sync requests:** a SYNC_REQUEST (§3.5) from the viewer means its decoder
lost the stream (§5). The host answers with a forced sync frame on the next
serviced tick, even if the region didn't change.
- Only the live region's current generation counts. A request for another
  region, an older generation, or a region whose START hasn't gone out is
  ignored. A new generation starts on a sync frame anyway.
- At most one answer every 500 ms (`syncRequestMinIntervalUS`). A request
  inside that window isn't dropped: it waits, and any number of them
  coalesce into one sync frame when the window ends. Sync frames are the
  most expensive frames there are, and the request comes from the peer, so
  a viewer asking on every frame still costs at most 2 sync frames a second.
- Any sync frame answers a pending request, a re-sharpen included. The
  answer also counts as the region's last sync for the re-sharpen.
- The answer re-claims every tile the host believes shows video, because
  the viewer dropped the claims of the frames it couldn't decode. Tiles
  already back on their exact canvas copy stay there.
- The parameter sets don't change within a generation and travel only in
  START. The viewer rebuilds its decoder from them, so the sync frame alone
  is enough.

### 4.7 Lossless keyframes (`HostEngine+Keyframes`, `KeyframeApplier`)

**Encoding:** a rect is encoded as 8 parallel VP8L stripes (≤ 7 MB) and sent as
KEYFRAME on the reliable video stream. The covered tiles go in flight under
the keyframe's seq.

**Applying:**
- The viewer applies the keyframe tile by tile under LWW, advances `tileSeq`
  and sends KEYFRAME_ACK.
- The host then commits through the seq guard.
- Timeout is `max(5·SRTT, 2 s) + bytes/50`. A timed-out keyframe sends its
  tiles cold.

**Used for:**
- the cold start of video-less sessions (headless agents,
  `GLASSACT_TILE_ONLY`), behind a lossy first paint;
- the cold-start fallback when the video encoder fails to start.

**Transient lossy paints** (`KeyframeCodec` 3) are the cold-start first
paint. They blit without advancing `tileSeq` and are never ACKed.

### 4.8 Scroll, cache and DELTA

**SCROLL** (`HostEngine+Scroll`):
- **Detection** runs on heavy ticks only, over the churn bbox:
  - vertical: row-signature votes;
  - horizontal: column signatures;
  - 2-D drag: a 128×128 anchor probe, ±640 px.
- **Verification:** every destination is memcmp-verified against the ACKed
  shadow, and the sources must be settled (INV-3).
- **Emission:**
  - SCROLL goes on **control**, with its own seq. The residual batch gets a
    strictly newer seq.
  - The host mirrors the shift on its shadow, promotes the known destinations
    speculatively, and clears the in-flight slots in the rect.
- **On the viewer:** the shift is LWW-gated per tile.
- **Repair** comes in SCROLL_ACK:
  - destinations of skipped sources go cold;
  - a digest mismatch demotes the whole rect;
  - a scroll un-ACKed within 32 newer scrolls is demoted.
- Scrolls that overlap a video region are suppressed.

**Tile cache** (`HostTileCache` / `ViewerTileCache`, 4096 slots):
- Content-addressed by xxh64 on the host and memcmp-verified; slot-addressed
  on the wire.
- **Host side:**
  - A slot is reused only when it is quiescent.
  - A slot is REF-able only after its STORE commits.
  - A STORE commits on ACK, and only while the tile still owns its slot.
- **Viewer side:**
  - A STORE stores on receipt, regardless of whether it won the canvas LWW.
  - A REF is hash-guarded. A miss NACKs, and the host then unindexes the slot.

**DELTA:**
- The base must be ACKed with nothing in flight, and the payload carries the
  base hash.
- The viewer hashes its tile. On a mismatch it drops the record and sends
  DELTA_NACK.
- The host's `repairAfterDeltaNack` zeroes `ackedHash` and clears the slot
  under the seq guard, so the bitmap ACK for that send counts as stale.

### 4.9 Rate control and pacing

**`SendGovernor`** — a token bucket for tiles:
- The bucket holds 0.25 s of rate, clamped to 64 KB–16 MB.
- **Automatic** mode:
  - Slow start at 2 MB/s, doubling per step until the first backoff; after
    that, ×1.25 per 200 ms.
  - Growth happens only while the governor is the limit and the standing
    queue is < 20 ms.
  - A standing queue > 60 ms backs off to 0.9 × the measured delivery rate;
    > 200 ms halves the rate.
  - A large batch that times out mostly unconfirmed halves the rate and holds
    for 1 s.
  - Encode duty caps growth: none above 50 %, and ×0.85 above 75 %.
  - The floor is 32 KB/s.
- **Capped** mode is a fixed 25, 50 or 100 Mbit/s (Host › Bandwidth).

**`PaceController`** sets the transport's datagram pacer, 10–120 MB/s, from
ACK-bitmap loss:
- loss > 10 % moves toward `rate × (1 − loss)`, at most halving;
- loss ≤ 2 % on a ≥ 2 MB batch probes up by 1/16.

**`VideoRateController`:**
- Measures drain rate in 250 ms windows.
- The send gate opens while the backlog is < rate × 60 ms. The encoder cap is
  0.85 × the estimate.
- It backs off when queueing delay (SRTT − min RTT) is > 60 ms and probes when
  it is < 30 ms, with CUBIC-style recovery.
- It starts capped at 3 Mbit/s until the link is measured, then rises ×1.25
  per clean window. The range is 300 kbit/s–20 Mbit/s.

**Resolution rung:** after 6 s of severe ACK delay, `onScalePressureConstrained` asks the
app to downscale capture for the rest of the session.

### 4.10 Session, geometry and windows

**Watchdogs:**
- Host: the handshake times out at 15 s; PONG silence > 10 s resets the session.
- Viewer: connect timeout 5 s; 10 s with no control bytes means the host is
  unresponsive.

**Redial:** only a `.lost` session redials, up to 20 times at 1 s intervals. The
count resets once a canvas is configured. A `.stopped` or `.hostKeyChanged`
session never redials.

**Geometry:**
- HELLO_OK may request a GeometryMode (§3.8). The host applies it, then
  re-offers HELLO with `geometryFinal`. If the geometry already matches, it
  re-offers on the same connection.
- In-session changes rebuild the host engine with seq continuity, and the
  viewer reconfigures with `tileSeq` reset.
- **Virtual display** (mode 4):
  - Uses the CGVirtualDisplay SPI: HiDPI 2×, up to 3840×2400 pt, mirrored
    `.forAppOnly`, so macOS undoes it when the Host exits.
  - Falls back to client resolution, which switches the physical display
    mode.
- **Display changes the Host didn't make** (someone at the Mac picks another
  resolution, rearranges displays or makes another display main): half a
  second after the reconfiguration settles, the Host checks the full-display
  capture against the display it shares, which is the one capture started
  on, not whichever is main now.
  - A moved display: input and cursor follow its new origin.
  - A new size at native: capture rebuilds at the new mode, in session.
  - A new shape under Scale: capture re-fits the viewer's last request.
  - Under client resolution, the viewer's mode is re-applied, as when macOS
    reverts it (at most 3 times a minute).
  - The Host's own switches rebuild capture as they make them, so they
    already match by then and the check does nothing.

**Single window:**
- WINDOW_LIST and WINDOW_SELECT rebuild the SCK filter around one window.
- WINDOW_CONTROL drives the window's chrome.
- If the shared window closes, the session ends without a redial.

**Pause:** a viewer whose window can't be seen (minimized, hidden, fully
covered) for 3 s sends PAUSE_HINT 1, and PAUSE_HINT 0 the moment it is
visible again.
- While paused the host ships no pixels at all (no tile records, video
  frames or keyframes): encode ticks return before collecting candidates,
  and their damage carries forward (`missedDirty`), so it re-qualifies on
  the first tick after resume. Control keeps flowing: PING/PONG, the
  viewer's re-ACKs, cursor and clipboard.
- An active video region is kept, not dissolved, and its quiet timer
  doesn't run, so resuming is a plain continuation with no settle repaint.
- The Host app drops capture to 1 fps while paused; the viewer releases its
  App Nap exemption.

---

## 5. Viewer engine (`ViewerEngine`)

**Canvas:** a contiguous BGRA buffer `w×h×4`, plus `tileSeq: [UInt32]` and a
dirty-tile set.

**Applying datagrams** (on `applyQueue`):
1. Parse with checked reads (§3.3).
2. Pre-gate each record with `newer(frame_seq, tileSeq[t])`. CACHE records
   bypass this so a STORE always stores.
3. Fragments go to the reassembler (§3.3). Completed records are re-gated.
4. Decode RAW, LZ4, LZBITMAP, VP8L (lossless-only decoder), DELTA or CACHE
   straight into the canvas rect.
5. `commitTile` sets `tileSeq` and marks the tile dirty.

**Received ≠ applied:** any record that would have won LWW but couldn't be
applied is NACKed (DELTA_NACK), so the host repairs it rather than trusting
the bitmap ACK. That covers records that were:
- malformed or undecodable;
- rejected by reassembly;
- expired in reassembly (250 ms).

**Video** (always an overlay; the canvas never holds video, INV-8):
- Frames decode into the overlay buffer.
- Claimed tiles set `overlayOn` and `overlaySeq`.
- A tile shows the overlay iff `overlayOn && newer(overlaySeq, tileSeq)`.
- STOP and REVEAL bitmaps clear `overlayOn` for tiles whose canvas copy is
  exact.
- **An undecodable frame asks for a sync frame.** A decoder rebuilt after a
  failure (a hardware session invalidated by sleep/wake or a media-engine
  reset, or corrupt data) drops every frame until a sync frame arrives, and
  the host sends those only on demand. So the first undecodable frame sends
  SYNC_REQUEST at once, and the viewer asks again at most every 500 ms
  while the region stays undecodable. The region recovers in place: no new
  START, and the session carries on.
- **Last resort:** a region still undecodable 2 s after its first failed
  frame fails the session, and the app reconnects. That leaves room for the
  first answer (a round trip plus a sync frame, which on a thin link can
  take most of a second) and for a re-ask or two if it fails too.

**ACK generation:** per-batch receive bitmaps, at the cadence in §3.5.

**Present** (`SurfacePresenter`):
- Two IOSurfaces form a flip pool. The blit runs on the apply queue and covers
  the union of the last **two** dirty drains (buffer age).
- Per tile it reads canvas or overlay, so video composites at present time
  (INV-8).
- The main thread only flips `layer.contents` on the display link.
- `magnificationFilter = .nearest` for 1:1.

**Cursor:** with the `cursor` cap, the pointer is a separate layer positioned
from CURSOR_POS and drawn from CURSOR_IMAGE. It never touches the canvas.

---

## 6. Transport

```swift
protocol GlassActTransport: AnyObject {
  var maxDatagramSize: Int { get }
  func sendControl(_ data: Data)          // reliable, ordered
  func sendDatagrams(_ batch: …)          // unreliable, paced
  var onControl / onDatagram / onVideo / onState …
}
```

**`QUICTransport`** (Network.framework). The ALPN is `glassact`, on two QUIC
tunnels:
- **Control tunnel:** an `NWConnectionGroup` on `port` (default 4433).
  - The host extracts the control stream and sends HELLO first.
  - The host also opens the video stream (preamble `0x56`) in this group.
  - Limits: 64 bidirectional streams, 64 MiB of connection data, 24 MiB per
    stream.
- **Datagram tunnel:** a separate datagram-only QUIC connection on `port + 1`.
  - It requests `maxDatagramFrameSize = 1400`; the effective value is read
    back once the tunnel is ready (1200 until then).
  - The datagrams are paced (§4.9).

**Classification:** a control tunnel's ALPN is only known once its handshake
completes, so the server starts each accepted tunnel and decides when it's
ready:
- `glassact` → a session. Only a classified session may displace one that
  is still establishing, so a dial refused at TLS can't cancel a viewer
  mid-connect.
- `glassact-signin` → one sign-in exchange (§3.9), at most 4 at once. It is
  never handed to the session code.
- anything else → closed.

The group's handlers are set once at accept and route to the group's current
owner. Swapping a handler can lose an event that was already queued for the
old one: a datagram tunnel parked until its control tunnel is classified
re-checks its state after the hand-off for the same reason.

Both tunnels:
- run full mutual TLS with the same identities (§13);
- idle out after 30 s, with QUIC keepalives every 5 s and a 10 s
  establishment timeout.

Why two tunnels instead of one: the transport is built on the
`NWConnectionGroup` API, which doesn't model QUIC datagrams alongside
streams (extracting a datagram flow from the group fails). The
`NetworkConnection` API does model both, but its datagram send is
async-only, with no batch or idempotent send, and its usable datagram frame
size reads 0 after establishment (BENCHMARKS "`NetworkConnection<QUIC>`
spike"), so the pixel path stays on the group API. **Issue #10** tracks
moving to one tunnel on `NetworkConnection` (one port, one handshake, no
tunnel pairing). The details are in the `## Deviations` note at the top of
`QUICTransport.swift`.

Tile records over QUIC streams (one stream per batch) stall under 1–3 %
random loss, so tile records stay on datagrams. Issue #10 tracks whether to
revisit them (BENCHMARKS "PROTOTYPE: tile records over QUIC streams").

**`InProcTransport`** (tests and bench) has the same interface and runs in
process. It adds deterministic, seeded fault injection: drop %, dup %,
reorder %, and a latency distribution. Every test that involves loss uses a
fixed seed.

---

## 7. Trace rig and metrics

**Recorder** (Host › Developer › Record Trace, or Record 30 Seconds):
- Writes `.scap` files to `~/Library/Application Support/Glass Act/traces/`.
- Header (11 B): `{magic "SCAP", ver u8, w u16, h u16, pixfmt u8, tile u8}`.
- Then, per frame: `{ts_us u64, rect_cnt u16, rects[(x,y,w,h) u16×4], lz4_len u32,
  lz4(full tightly-packed frame)}`. `rect_cnt = 0` means no dirty info, so the
  replay does a full scan.

**`glassact-bench`** feeds a `.scap` into the host engine as if it came from SCK:
the same inputs give the same outputs.
- `replay --mode encode`: bytes/frame and stage timings, with instant ACKs.
  `--count-allocs` adds the heap allocations made inside each tick.
- `replay --mode loop`: host → InProc faults → viewer, over virtual time.
- `synth`: synthetic traces.
- `glassact-bench help` lists the rest.

**`glassact-trace`** inspects and diffs traces.

**Golden divergence test:**
1. Replay a trace under seeded faults. The standard mix is 5 % drop, 1 % dup,
   10 % reorder and 20–80 ms jitter.
2. Keep ticking on the final frame until nothing is open and nothing
   qualifies.
3. Assert that the viewer canvas is **byte-identical** to the final capture.
   Zero tolerance.

Video is excluded from goldens; it is lossy by design, and the lossless
handoff is what converges.

**Signposts** (`os_signpost`, keyed by `frame_seq`):
- host: capture, diff, encode, pack, tx;
- viewer: rx, parse, apply, present.

`SessionTelemetry` keeps counters for bytes, tiles, dropped batches and lost
datagrams.

---

## 8. Swift performance rules

These apply to the hot paths: diff, encode, parse, apply and blit.

1. **Zero heap allocation per frame.** Use preallocated arenas and
   capacity-reserved, reused worklists (`removeAll(keepingCapacity: true)`).
   The known exceptions are listed under INV-7.
2. **No ARC in tile loops.** Use `Unsafe*BufferPointer` slices, hoist object
   access out of loops, and avoid capturing closures in loop bodies.
3. **No `String`, `Data` appends or dictionaries in per-tile paths.** Use flat
   arrays indexed by `tile_idx`.
4. **Plain `-O` everywhere, never `-Ounchecked`.** It was measured to gain
   nothing while stripping the bounds checks that guard canvas writes
   (BENCHMARKS "`-Ounchecked` on GlassActCodec"). Wire parsing stays checked
   regardless (INV-6).
5. **`@inline(__always)` on tiny helpers:** varint, hash rounds, pixel
   addressing.
6. **SIMD** (`SIMD16<UInt8>` / `SIMD4<UInt32>`) where natural. Otherwise trust
   the auto-vectorizer and check `-emit-assembly`.
7. **Measure before optimizing.** Every perf claim needs a `glassact-bench`
   number on a named trace, recorded in BENCHMARKS.md.
8. **Swift 6 strict concurrency.** Engines are queue-confined `final class`es
   marked `@unchecked Sendable`, with the queue documented. Never add actors
   or `await` to the pixel path to satisfy the checker; confine instead.
   Parallelism inside a tick uses `concurrentPerform` over disjoint per-tile
   writes.

---

## 9. Repository layout

```
Package.swift              tools 6.4, macOS 15.5, warnings as errors
Sources/
  GlassActWire/            bytes: varint, TLV, datagrams, control, video, serial (checked)
  GlassActCodec/           xxh64, RAW/LZ4/LZBITMAP/VP8L tile codecs, arenas
  GlassActCore/            HostEngine(+Acks/Encode/Keyframes/Scroll/Video), ViewerEngine,
                           TileLedger, governor/pacing/video rate, VT HEVC, presenter, .scap
  GlassActTransport/       transport protocol, QUICTransport, InProcTransport, identity,
                           known hosts, authorized viewers, AppPaths
  GlassActSession/         ViewerSession, AgentDriver, HeadlessAgent, agent socket, MCP
  glassact/                CLI + MCP server + headless daemon
  glassact-bench/          replay, synth, goldens, codec experiments
  glassact-trace/          .scap inspection and diff
Tests/                     WireTests CodecTests CoreTests TransportTests SessionTests
                           (+ GlassActTestSupport)
ThirdParty/libwebp/        vendored, BSD-3 (VP8L encode/decode)
Apps/GlassActApps.xcodeproj
  Host/                    menu-bar app: capture, input, approvals, agents policy
  Viewer/                  window app: connect, render, input, settings
  Signing.xcconfig         (+ git-ignored Signing.local.xcconfig), release.sh
Justfile                   test, test-fast, test-asan, test-exhaustive, build, bench, release, install-cli
docs/                      this file
BENCHMARKS.md              the measurement record (§12)
AGENTS.md, CONTRIBUTING.md working guide and contributor setup
```

The apps stay thin, with UI and wiring only. Logic lives in the package, so
`swift test` covers it.

---

## 10. History

Glass Act started from a v1 spec: tiles, last-writer-wins, ACKs and QUIC
(§1–§6), with later work reserved as phases P2–P8 (§11). BENCHMARKS.md
names its entries by those phases. Each has the numbers for its step, and
its decisions table lists what was tried and dropped. The phases:

| phase | what it became |
|---|---|
| v1 (M0–M4) | the package, wire and engines; invariant, property and fuzz tests; goldens under seeded faults; capture, QUIC, the two apps and the acceptance run (§10.1) |
| P2′ | DELTA records and NACKs (§4.8) |
| P3, P3′, P3″ | scroll, then window-scoped and horizontal scroll, then 2-D drag (§4.8) |
| P3b | the session tile cache (§4.8) |
| P6, P6b–P6e | HEVC video regions, the send governor and automatic send rate (§4.6, §4.9) |
| P7, P7b | lossless keyframes and the lossy first paint (§4.7) |
| P8 | pinned full-screen video, then the overlay and per-tile handoff (§4.6) |

Alongside those: the LZBITMAP and VP8L tile codecs, the cursor as metadata,
remote input and clipboard, mutual TLS with sign-in and approvals (§13),
geometry modes and the virtual display, single-window mode, and agents
(§14). P2 (palette), P4 (DCT) and P5 (Metal) were not built; §11 says why.

### 10.1 v1 acceptance

These are the v1 acceptance bars. Their status is in BENCHMARKS "§10.1 acceptance
status".

- All invariant, property and fuzz tests green. Goldens byte-exact at
  5 %/1 %/10 % across 3 seeds.
- `typing`: encode p95 ≤ 300 µs/batch; sustained ≤ 120 KB/s.
- `idle`: 0 datagrams after settle.
- `scroll` (4K): no capture starvation on loopback at 60 Hz.
- Loopback glass-to-glass p50 ≤ 35 ms at 60 Hz (measured: 34.6 ms).

---

## 11. Roadmap status

| v1 reservation | outcome |
|---|---|
| P2 palette + rANS + YCoCg-R | not built. LZBITMAP and VP8L took the text/UI role; cursor-as-metadata shipped |
| P3 COPY + scroll + cache | built as SCROLL (control TLV, not opcode 0x03) and CACHE (0x07) |
| P4 DCT + REFINE | REFINE measured and rejected (the diff was larger than full lossless); DCT superseded by video regions |
| P5 Metal surge path | not built; hardware HEVC covers surges |
| P6 video regions | built on its own stream (not opcode 0x08); pinned full-screen HEVC with the overlay is the only mode |
| P6 partial regions and codec ladder | not kept: hot-map partial-screen regions (with in-place resize) and the CPU-pressure codec demote/promote ladder; pinned full-screen video supersedes both (BENCHMARKS decisions table). AV1 stays reserved for hardware encode; the codec-keyed factory keeps a second codec pluggable |

Open work is in GitHub issues (labels: `performance`, `security`, `research`,
`macos`, `agents`).

---

## 12. Working agreements

- Until 1.0 the wire protocol may change in any release: bump
  `WireVersion.current`, and keep no old decode paths or migration code.
  Both ends must run the same build.
- **No new dependencies.** System frameworks only, plus the vendored libwebp.
- Every invariant keeps an `INV_*` test, and a failing one blocks merge.
- Perf-relevant changes include before/after `glassact-bench` output on a
  named trace. A regression over 10 % needs a written justification.
- When SDK API shapes differ from this document (especially
  Network.framework), match the SDK and record the delta in a `## Deviations`
  note at the top of the file.
- Keep BENCHMARKS.md current. It is the project's memory.

---

## 13. Security model

**Encryption:** always on, with no way to turn it off.
- QUIC is the only network transport, and QUIC requires TLS 1.3.
- That covers the control stream, the video stream and the pixel datagrams.
  QUIC datagrams get the same packet protection as streams.
- Both tunnels run full mutual TLS.
- Certificates travel after the handshake is encrypted, so a passive observer
  can't tell which Viewer key is connecting.

What an observer still sees:
- **Addresses and ports.**
- **That it's Glass Act.** QUIC Initial packets are encrypted with keys anyone
  can derive, so the `glassact` ALPN is effectively readable.
- **Traffic size and timing.** Because idle sends zero bytes (INV-10), when the
  screen changes, roughly how much, and possibly typing rhythm are all visible.
  This is a known limit: padding or cover traffic would cost the idle
  guarantee.
- **The Bonjour advertisement.** It's unencrypted and names the Mac.

**Identities:**
- Every key is P-256, in a self-signed certificate named `glassact-host`,
  `glassact-viewer` or `glassact-agent`.
- **Key ID:** the SHA-256 of the key's SubjectPublicKeyInfo DER (the standard
  SPKI pin), in lowercase hex. It names the key, not the certificate, so a
  re-issued certificate keeps the device's identity.
- **Key strings:** for people, a key ID is shown and copied as Bech32 with the
  prefix `ga` ("ga1" then 58 characters). The checksum catches typos instead
  of naming another key. Everything that takes a key accepts either form.
- **Host and Viewer** keep their identity in the data protection keychain
  (`KeychainIdentity`), in the app's own keychain access group:
  - The private key is made in the **Secure Enclave** when the Mac has one
    (Apple silicon, or an Intel Mac with a T2), so it can't be exported or
    copied to another Mac. Elsewhere it's a software key in the keychain.
  - Items are `…AfterFirstUnlockThisDeviceOnly` and never synchronized:
    each Mac has its own identity, so one can be revoked alone.
  - The access group comes from the `keychain-access-groups` entitlement,
    which needs the team's provisioning profile. It admits every build the
    team signs, Debug and Release alike, with no keychain prompts.
  - A build without that entitlement (no signing team) falls back to the
    file identity below. Any other keychain failure is an error, not a
    fallback: a silent switch would change the Mac's identity.
- **The `glassact` CLI** (headless agents), and unsigned builds, keep a file
  identity: PKCS#12 in `~/Library/Application Support/Glass Act` (directory
  0700, file 0600, written atomically), imported memory-only. A bare
  executable can't carry a provisioning profile. The PKCS#12 passphrase is a
  fixed constant, so the file's permissions are its only protection.
  - A key file that can be read but not imported (another passphrase,
    corruption) is replaced with a fresh identity. Peers then see a new key:
    a host refuses it as changed, and an agent is approved again.
  - Once an app's identity is in the keychain, its old key file is deleted.

**Viewer → host:**
- The viewer pins the host's fingerprint if one was given.
- Otherwise it trusts on first use and records `host:port <key ID>` in
  `known_host_keys`, with SSH accept-new semantics.
- A changed key is a hard refusal. The viewer never redials into it.

**Host → viewer:**
- Mutual TLS on both tunnels. The host's verify block admits only
  key IDs in `approved_viewers`, so everyone else is refused during the
  handshake, before any app data.
- What happens to an unknown key is the Host's **New Viewers** setting
  (`NewViewerPolicy`):
  - **Sign in** (default): refused with no dialog. The viewer then signs in
    over §3.9 with the name and password of the account running the Host
    (its short or full name). A match approves the key it presented, with
    full control. The Host posts a quiet notification.
  - **Ask**: an approval prompt, Don't Allow (the default) or Allow, with
    the verification code. Denials last for the current run.
  - **Don't allow**: refused, silently.
  - **Agents** never sign in. Their keys get the prompt (with View Only),
    unless new viewers aren't allowed at all.
- **Password checks** (`LocalAccountVerifier`) use OpenDirectory. A wrong
  name is refused without asking OpenDirectory. A wrong password counts
  toward the account's macOS `failedLoginCount`, so `SignInThrottle` keeps
  far below any lockout policy:
  - per address: free, then 5 s, 30 s and 2 min between tries;
  - for everyone: 5 failures per 15 minutes, then sign-in waits;
  - checks run one at a time, and every wrong answer takes at least 1 s.
- **The password only goes to the key the viewer trusts**: the pinned or
  known one, or on a first connection the key the refused dial just
  presented. A mismatch stops the exchange before anything is sent. A
  first-ever connection is still trust on first use: an active attacker on
  that very first exchange could capture the password. The viewer shows the
  host's key prefix so it can be compared.
- Both sides show a **verification code** for the pair of keys: 80 bits of
  SHA-256 over a domain separator (`…-v2`) plus both key IDs, as 16 Crockford
  base32 characters. Matching codes rule out a man in the middle, which also
  covers the viewer's first-use trust.
- `approved_viewers` has one line per key:
  `<key ID> [view] [kind=] [label=] [device=] [name=] [addr=] [approved=] [seen=]`.
  A bare key ID means full control.

**Known limits:**
- Any process running as the same user can read the CLI's key file (and an
  unsigned build's), and can use the agent sockets. The Host's and Viewer's
  keys can't be read; code signed by another team can't use them either.
- Agent status is self-declared, by certificate name or the input flag, so a
  modified client can avoid agent policy.
- Under "Ask", nothing rate-limits approval prompts from new keys. (Under
  "Sign in", new keys cause no prompts.)
- First contact is only as safe as the person comparing codes.
- The apps are unsandboxed (issue #8) and use private API: CGVirtualDisplay
  and `SACLockScreenImmediate`.
- Bonjour advertises the computer name.

---

## 14. Agents

`GlassActSession` exposes a session to programs. A session is either:
- a **headless** agent connection (`HeadlessAgent`, run by `glassact daemon`),
  or
- the Viewer's own live session (`viewer.sock`, opt-in in Viewer › Settings).

**`AgentDriver`:**
- Uses a computer-use vocabulary: screenshot, zoom, click, drag, scroll, key,
  type, waits, UI tree, windows, clipboard.
- Agent coordinates use a space whose longest edge is ≤ 1568 px. With
  `--size`, a virtual display makes agent coordinates equal host points.
- A screenshot waits for the screen to settle, tolerating 0.5 % of tiles still
  changing.

**Socket protocol** (`AgentSocket`):
- Newline-delimited JSON, `{id, op, args}` → `{id, ok, result|error}`.
- Sockets live in `…/Glass Act/agent/`: directory 0700, sockets 0600, with a
  `getpeereid` uid check.
- A request buffer over 8 MB drops the client.

**Front ends:** the `glassact` CLI, and an MCP server (`glassact mcp`,
hand-rolled JSON-RPC 2.0 over stdio) whose tools mirror computer use.

**Host policy** (`AgentAccess`):
- A connection is an agent if its certificate name is `glassact-agent`, or if
  its input carries the agent flag.
- View Only blocks input, the clipboard and window control.
- "Allow Agents to Control This Mac" is a global switch.
- Time limit: none, 15 min, 1 h (the default) or 4 h. When it runs out, agent
  input pauses until the user resumes it.
- **The human wins:** agent input is refused for 2 s after local HID input.
  Releases always pass, so keys never stick.
- An audit log (`agent-audit.log`, 0600, rotated at 4 MB) records every action.
  Typed text is counted, not recorded.
- A headless agent leaving doesn't trigger the lock-on-leave.

A private display for agents is deferred (issue #7).
