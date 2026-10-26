import Testing
import GlassActWire
import GlassActTestSupport

@Suite struct ControlTests {
    private func roundTrip(_ m: ControlMessage) {
        var d = ControlDeframer()
        d.append(m.encoded())
        #expect(d.next() == .message(m))
        #expect(d.next() == nil)
        #expect(!d.isMalformed)
    }

    @Test func helloRoundTrip() {
        roundTrip(.hello(ver: 1, width: 3840, height: 2160, tileSize: 64, pixfmt: 1, caps: 0xA5A5_5A5A))
    }

    @Test func helloOKRoundTrip() {
        roundTrip(.helloOK(ver: 1, caps: 7, geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0))
        roundTrip(.helloOK(ver: 1, caps: 0, geoMode: 1, geoWidth: 1470, geoHeight: 956, geoScale: 2))
        roundTrip(.helloOK(ver: 1, caps: 0, geoMode: 3, geoWidth: 0, geoHeight: 0, geoScale: 0))
    }

    @Test func helloOKGeometryModes() {
        roundTrip(.helloOK(ver: 1, caps: 0, geoMode: GeometryMode.virtualDisplay,
                           geoWidth: 1470, geoHeight: 918, geoScale: 2))
        var d = ControlDeframer()
        d.append(ControlMessage.helloOK(ver: 1, caps: 0, geoMode: 5,
                                        geoWidth: 1, geoHeight: 1, geoScale: 1).encoded())
        #expect(d.next() == nil && d.isMalformed, "an unknown geometry mode must not parse")
    }

    @Test func scrollRoundTrip() {
        roundTrip(.scroll(frameSeq: 77, x: 0, y: 128, width: 5120, height: 2624, dx: 0, dy: 192))
        roundTrip(.scroll(frameSeq: 78, x: 64, y: 0, width: 100, height: 50, dx: -32, dy: -600))
    }

    @Test func scrollAckRoundTrip() {
        roundTrip(.scrollAck(frameSeq: 9, skipped: [], digest: 0))
        roundTrip(.scrollAck(frameSeq: 10, skipped: [0, 17, 3599], digest: 0xDEAD_BEEF_F00D_CAFE))
        roundTrip(.scrollAck(frameSeq: 11, skipped: (0..<500).map { UInt16($0) }, digest: .max))
    }

    @Test func deltaNackRoundTrip() {
        roundTrip(.deltaNack(frameSeq: 12, tiles: []))
        roundTrip(.deltaNack(frameSeq: 13, tiles: [181]))
        roundTrip(.deltaNack(frameSeq: 14, tiles: (0..<300).map { UInt16($0) }))
    }

    @Test func cursorRoundTrip() {
        roundTrip(.cursorPos(x: 0, y: 0, visible: false))
        roundTrip(.cursorPos(x: 5119, y: 2879, visible: true))
        var rng = SplitMix64(seed: 15)
        roundTrip(.cursorImage(width: 32, height: 32, hotspotX: 4, hotspotY: 4,
                               scale: 2, bgra: rng.bytes(32 * 32 * 4)))
    }

    @Test func inputRoundTrip() {
        roundTrip(.input(kind: 1, x: 2560, y: 1440, a: 0, b: 0))
        roundTrip(.input(kind: 2, x: 0, y: 0, a: 0, b: 1))
        roundTrip(.input(kind: 2, x: 640, y: 480, a: 2, b: 0)) // double-click: a = click count
        roundTrip(.input(kind: 4, x: 100, y: 200, a: -3, b: 5))
        roundTrip(.input(kind: 5, x: 0x35, y: 0, a: Int32(bitPattern: 0x0010_0000), b: 0))
    }

    @Test func viewerLogRoundTripAndSafety() {
        roundTrip(.viewerLog(name: "viewer-20260929-160934.log", offset: 0, total: 3, data: [1, 2, 3]))
        roundTrip(.viewerLog(name: "a", offset: 8192, total: 9000, data: Array(repeating: 7, count: 808)))
        // The host writes `name` under its own directory: only bare, safe names.
        for bad in ["../etc/passwd", "/tmp/x", ".hidden", "a/b", "a b", "ü.log", "", String(repeating: "x", count: 65)] {
            #expect(!ControlMessage.isSafeLogName(bad), "\(bad)")
            var d = ControlDeframer()
            d.append(ControlMessage.viewerLog(name: bad, offset: 0, total: 1, data: [0]).encoded())
            #expect(d.next() == nil && d.isMalformed, "unsafe name must not parse: \(bad)")
        }
        // A chunk past `total`, or a total over the cap, is malformed.
        for m in [ControlMessage.viewerLog(name: "x.log", offset: 5, total: 6, data: [1, 2]),
                  ControlMessage.viewerLog(name: "x.log", offset: 0, total: ControlMessage.maxViewerLogTotal + 1, data: [])] {
            var d = ControlDeframer()
            d.append(m.encoded())
            #expect(d.next() == nil && d.isMalformed)
        }
    }

    /// Kind 7 (pixel scroll) and any future kind must parse — a range check
    /// would make the first trackpad scroll a malformed stream (killing the
    /// session).
    /// Kind 0 stays invalid.
    @Test func inputKindsAreAdditive() {
        roundTrip(.input(kind: 7, x: 100, y: 200, a: -12, b: 37))
        roundTrip(.input(kind: 200, x: 1, y: 2, a: 3, b: 4))
        var zero = ControlMessage.input(kind: 1, x: 0, y: 0, a: 0, b: 0).encoded()
        zero[2] = 0 // type, len, then kind
        var d = ControlDeframer()
        d.append(zero)
        #expect(d.next() == nil || d.isMalformed, "kind 0 is invalid")
    }

    @Test func clipboardRoundTrip() {
        roundTrip(.clipboard(format: 1, data: Array("hello world".utf8)))
        roundTrip(.clipboard(format: 1, data: []))
        var rng = SplitMix64(seed: 24)
        roundTrip(.clipboard(format: 1, data: rng.bytes(50_000)))
    }

    @Test func qualityRoundTrip() {
        roundTrip(.quality(presentedScalePct: 100, floor: QualityFloor.automatic, preferSharpness: 0))
        roundTrip(.quality(presentedScalePct: 50, floor: QualityFloor.medium, preferSharpness: 1))
        roundTrip(.quality(presentedScalePct: 0, floor: QualityFloor.low, preferSharpness: 0))
        var d = ControlDeframer()
        d.append(ControlMessage.quality(presentedScalePct: 100, floor: 4, preferSharpness: 0).encoded())
        #expect(d.next() == nil && d.isMalformed, "floor is 0–3")
        roundTrip(.quality(presentedScalePct: 100, floor: QualityFloor.automatic, preferSharpness: 2))
        var e = ControlDeframer()
        e.append(ControlMessage.quality(presentedScalePct: 100, floor: 0, preferSharpness: 3).encoded())
        #expect(e.next() == nil && e.isMalformed, "the preference is 0–2")
    }

    @Test func windowListRoundTrip() {
        var rng = SplitMix64(seed: 26)
        roundTrip(.windowList(windows: []))
        roundTrip(.windowList(windows: [
            WireWindow(windowID: 42, appName: "Safari", title: "Glass Act — Wikipedia",
                       thumbFormat: WindowThumbFormat.webpLossy, thumbWidth: 320, thumbHeight: 200,
                       thumb: rng.bytes(4_000)),
            WireWindow(windowID: 0xDEAD_BEEF, appName: "", title: "无标题窗口 🪟",
                       thumbFormat: WindowThumbFormat.none, thumbWidth: 0, thumbHeight: 0, thumb: []),
            WireWindow(windowID: 7, appName: "Terminal", title: "zsh",
                       thumbFormat: WindowThumbFormat.avif, thumbWidth: 256, thumbHeight: 160,
                       thumb: rng.bytes(1_200)),
        ]))
    }

    @Test func windowSelectRoundTrip() {
        roundTrip(.windowSelect(windowID: 0))
        roundTrip(.windowSelect(windowID: 0xFFFF_FFFF))
    }

    @Test func windowControlRoundTrip() {
        roundTrip(.windowControl(action: WindowAction.fullscreen, width: 0, height: 0))
        roundTrip(.windowControl(action: WindowAction.resize, width: 1280, height: 800))
        roundTrip(.windowControl(action: WindowAction.endSession, width: 0, height: 0))
        // action 0 and 4 are invalid.
        for badAction in [UInt8(0), UInt8(4)] {
            var bad = ByteWriter()
            bad.writeU8(0x13)
            bad.writeVarint(5)
            bad.writeU8(badAction)
            bad.writeU16(0); bad.writeU16(0)
            var d = ControlDeframer()
            d.append(bad.bytes)
            #expect(d.next() == nil)
            #expect(d.isMalformed)
        }
    }

    @Test func resizeRoundTrip() {
        roundTrip(.resize(mode: 1, width: 1512, height: 982, scale: 2))
        roundTrip(.resize(mode: 2, width: 1280, height: 800, scale: 2))
        roundTrip(.resize(mode: GeometryMode.virtualDisplay, width: 1470, height: 923, scale: 2))
        var d = ControlDeframer()
        d.append(ControlMessage.resize(mode: 3, width: 1, height: 1, scale: 1).encoded())
        #expect(d.next() == nil && d.isMalformed, "RESIZE takes 1, 2 or 4 — native is handshake-only")
    }

    @Test func pauseHintRoundTrip() {
        roundTrip(.pauseHint(paused: true))
        roundTrip(.pauseHint(paused: false))
        #expect(ControlMessage.pauseHint(paused: true).encoded() == [0x08, 1, 1])
        var d = ControlDeframer()
        d.append([0x08, 1, 2]) // paused is 0 or 1
        #expect(d.next() == nil && d.isMalformed)
    }

    @Test func pingPongRoundTrip() {
        roundTrip(.ping(nonce: 0x1122_3344_5566_7788, tUS: 42))
        roundTrip(.pong(nonce: 1, tUS: 2, recvTUS: 3))
    }

    @Test(arguments: [1, 7, 8, 9, 16, 17, 2040, 65_535] as [Int])
    func ackRoundTrip(dgramCnt: Int) {
        var rng = SplitMix64(seed: UInt64(dgramCnt))
        let bitmap = rng.bytes((dgramCnt + 7) / 8)
        roundTrip(.ack(frameSeq: 0xFEED_F00D, dgramCnt: UInt16(dgramCnt), bitmap: bitmap))
    }

    @Test func byteByByteDelivery() {
        let messages: [ControlMessage] = [
            .hello(ver: 1, width: 1920, height: 1080, tileSize: 64, pixfmt: 1, caps: 0),
            .ack(frameSeq: 9, dgramCnt: 3, bitmap: [0b101]),
            .ping(nonce: 5, tUS: 6),
        ]
        var d = ControlDeframer()
        var events: [ControlDeframer.Event] = []
        for byte in messages.flatMap({ $0.encoded() }) {
            d.append([byte])
            while let e = d.next() { events.append(e) }
        }
        let expected: [ControlDeframer.Event] = messages.map { .message($0) }
        #expect(events == expected)
        #expect(!d.isMalformed)
    }

    @Test func multipleMessagesInOneChunk() {
        let messages: [ControlMessage] = [
            .ping(nonce: 1, tUS: 2),
            .pong(nonce: 1, tUS: 2, recvTUS: 3),
            .ack(frameSeq: 4, dgramCnt: 9, bitmap: [0xFF, 0x01]),
        ]
        var d = ControlDeframer()
        d.append(messages.flatMap { $0.encoded() })
        for m in messages {
            #expect(d.next() == .message(m))
        }
        #expect(d.next() == nil)
    }

    @Test func unknownTypesAreSkipped() {
        var unknown = ByteWriter()
        unknown.writeU8(0x1E) // beyond the assigned range (deframer skips by length)
        unknown.writeVarint(3)
        unknown.writeBytes([1, 2, 3] as [UInt8])
        var stream = unknown.bytes
        stream.append(contentsOf: ControlMessage.ping(nonce: 1, tUS: 2).encoded())
        var d = ControlDeframer()
        d.append(stream)
        #expect(d.next() == .skippedUnknown(type: 0x1E))
        #expect(d.next() == .message(.ping(nonce: 1, tUS: 2)))
        #expect(d.next() == nil)
        #expect(!d.isMalformed)
    }

    @Test func knownTypeWithBadBodyIsMalformed() {
        var bad = ByteWriter()
        bad.writeU8(0x04) // PING body must be 16 bytes
        bad.writeVarint(3)
        bad.writeBytes([1, 2, 3] as [UInt8])
        var d = ControlDeframer()
        d.append(bad.bytes)
        #expect(d.next() == nil)
        #expect(d.isMalformed)
    }

    /// The bitmap is as long as the count needs; a byte past it is a newer
    /// peer's appended field (§12), not more bitmap.
    @Test func ackBitmapReadsOnlyWhatTheCountNeeds() {
        var w = ByteWriter()
        w.writeU8(0x03)
        w.writeVarint(4 + 2 + 2) // frame_seq + dgram_cnt + 2 bytes
        w.writeU32(1)
        w.writeU16(3)            // cnt 3 needs 1 bitmap byte; the 2nd is appended
        w.writeBytes([0xFF, 0xAB] as [UInt8])
        var d = ControlDeframer()
        d.append(w.bytes)
        #expect(d.next() == .message(.ack(frameSeq: 1, dgramCnt: 3, bitmap: [0xFF])))
        #expect(!d.isMalformed)
    }

    @Test func oversizeBodyIsMalformed() {
        var bad = ByteWriter()
        bad.writeU8(0x0A)
        bad.writeVarint(ControlDeframer.maxBodyLength + 1)
        var d = ControlDeframer()
        d.append(bad.bytes)
        #expect(d.next() == nil)
        #expect(d.isMalformed)
    }

    @Test func fourByteContinuationLengthIsMalformed() {
        var d = ControlDeframer()
        d.append([0x01, 0x80, 0x80, 0x80, 0x80] as [UInt8])
        #expect(d.next() == nil)
        #expect(d.isMalformed)
    }

    /// The sender-side bound: a body the receiver would reject (and tear
    /// the stream down over) must never be produced for sending. An
    /// exactly-1 MiB clipboard is one byte over (format byte + data).
    @Test func encodedForSendRefusesOversizeBodies() {
        let atLimit = ControlMessage.clipboard(format: 1,
                                               data: [UInt8](repeating: 0x61, count: ControlMessage.maxClipboardBytes))
        guard let bytes = atLimit.encodedForSend() else {
            Issue.record("the largest legal clipboard must encode")
            return
        }
        var d = ControlDeframer()
        d.append(bytes)
        #expect(d.next() == .message(atLimit))
        #expect(!d.isMalformed)
        let over = ControlMessage.clipboard(format: 1, data: [UInt8](repeating: 0x61, count: 1 << 20))
        #expect(over.encodedForSend() == nil, "1 MiB of data + the format byte exceeds the bound")
        let video = VideoMessage.frame(region: 0, generation: 1, seq: 1, sync: true, captureUS: 0,
                                       data: [UInt8](repeating: 0, count: Int(VideoMessage.maxBodyLength)))
        #expect(video.encodedForSend() == nil)
    }

    /// Counts are validated against the body before anything is reserved
    /// (INV-6): a 2-byte window list claiming 65 535 windows is rejected
    /// up front rather than reserving ~3.7 MB first.
    @Test func countsAreValidatedBeforeAllocation() {
        for (type, body) in [(UInt8(0x11), [0xFF, 0xFF] as [UInt8]),            // windowList
                             (0x0A, [0, 0, 0, 1, 0xFF, 0xFF]),                  // deltaNack
                             (0x07, [0, 0, 0, 1, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0])] { // scrollAck
            var w = ByteWriter()
            w.writeU8(type)
            w.writeVarint(UInt32(body.count))
            w.writeBytes(body)
            var d = ControlDeframer()
            d.append(w.bytes)
            #expect(d.next() == nil)
            #expect(d.isMalformed, "type \(type) with an impossible count must be rejected")
        }
    }

    // MARK: Agents

    private func rejects(type: UInt8, body: [UInt8], _ why: String) {
        var frame: [UInt8] = [type]
        var w = ByteWriter(reserving: 4)
        w.writeVarint(UInt32(body.count))
        frame += w.bytes + body
        var d = ControlDeframer()
        d.append(frame)
        #expect(d.next() == nil && d.isMalformed, "\(why)")
    }

    @Test func agentMessagesRoundTrip() {
        roundTrip(.textInput(text: "hello"))
        roundTrip(.textInput(text: "Ünïcödé — 日本語 👩🏽‍💻"))
        roundTrip(.agentState(active: true, label: "Claude"))
        roundTrip(.agentState(active: false, label: ""))
        roundTrip(.uiTreeRequest(requestID: 7, windowID: 0, maxNodes: 400))
        roundTrip(.uiTree(requestID: 7, status: UITreeStatus.ok, json: Array(#"{"role":"AXWindow"}"#.utf8)))
        roundTrip(.uiTree(requestID: 8, status: UITreeStatus.notPermitted, json: []))
        roundTrip(.agentScope(control: false, reason: "view-only approval"))
        roundTrip(.input(kind: 2 | InputFlags.agent, x: 10, y: 20, a: 1, b: 0))
        roundTrip(.viewerInfo(name: "Alex’s MacBook Air"))
    }

    @Test func malformedAgentMessagesAreRejected() {
        rejects(type: 0x15, body: [], "empty TEXT_INPUT")
        rejects(type: 0x15, body: [0xC3], "truncated UTF-8")
        rejects(type: 0x15, body: [UInt8](repeating: 0x61, count: ControlMessage.maxTextInputBytes + 1), "oversize text")
        rejects(type: 0x16, body: [2, 0], "active must be 0 or 1")
        rejects(type: 0x16, body: [1, 5, 0x61], "label shorter than declared")
        rejects(type: 0x16, body: [1, 65] + [UInt8](repeating: 0x61, count: 65), "label over 64 bytes")
        rejects(type: 0x17, body: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "maxNodes 0")
        rejects(type: 0x18, body: [1, 0, 0, 0, 9], "unknown UI_TREE status")
        rejects(type: 0x19, body: [1, 3, 0x61], "reason shorter than declared")
        rejects(type: 0x1A, body: [], "empty viewer name")
        rejects(type: 0x1A, body: [UInt8](repeating: 0x61, count: 65), "viewer name over 64 bytes")
    }

    @Test func syncRequestRoundTripAndLayout() {
        roundTrip(.syncRequest(region: 0, generation: 1))
        roundTrip(.syncRequest(region: 3, generation: 0xFFFF_FFFF))
        // type 0x1B, len 5, region u8, generation u32 LE.
        #expect(ControlMessage.syncRequest(region: 2, generation: 0x0403_0201).encoded()
                == [0x1B, 5, 2, 0x01, 0x02, 0x03, 0x04])
        #expect(ControlMessage.isKnownType(0x1B))
    }

    @Test func malformedSyncRequestsAreRejected() {
        rejects(type: 0x1B, body: [], "empty SYNC_REQUEST")
        rejects(type: 0x1B, body: [0, 1, 0, 0], "generation truncated")
    }

    @Test func textChunksStayUnderTheBoundAtCharacterBoundaries() {
        let text = String(repeating: "é👍a", count: 2000) // 2 + 4 + 1 bytes each
        let chunks = text.utf8Chunks(maxBytes: ControlMessage.maxTextInputBytes)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { (1...ControlMessage.maxTextInputBytes).contains($0.utf8.count) })
        #expect("abc".utf8Chunks(maxBytes: 4096) == ["abc"])
        #expect("".utf8Chunks(maxBytes: 4096).isEmpty)
        #expect("héllo".utf8Prefix(2) == "h")
        #expect("héllo".utf8Prefix(3) == "hé")
    }
}
