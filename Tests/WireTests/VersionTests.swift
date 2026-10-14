import Testing
import GlassActWire

@Suite struct VersionTests {
    @Test func currentVersionIsThree() {
        #expect(WireVersion.current == 3) // v3: video is always the overlay
        #expect(DatagramHeader.wireVersion == WireVersion.current)
    }

    @Test func compatibilityIsExactMatch() {
        #expect(WireVersion.isCompatible(WireVersion.current))
        #expect(!WireVersion.isCompatible(0))
        #expect(!WireVersion.isCompatible(1))
        #expect(!WireVersion.isCompatible(15))
    }

    @Test func handshakeMessagesCarryTheVersionField() {
        // The version travels in HELLO/HELLO_OK and must survive the round trip.
        var d = ControlDeframer()
        d.append(ControlMessage.hello(ver: WireVersion.current, width: 1920, height: 1080,
                                      tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0).encoded())
        guard case let .message(.hello(ver, _, _, _, pixfmt, _)) = d.next() else {
            Issue.record("expected HELLO")
            return
        }
        #expect(ver == WireVersion.current)
        #expect(pixfmt == PixelFormat.bgra8sRGB)
    }
}
