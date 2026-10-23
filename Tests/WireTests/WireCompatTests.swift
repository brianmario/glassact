import Testing
import GlassActWire

/// Cross-version compatibility (§12): a Host and Viewer of different
/// releases must work together, so the wire only grows.
///
/// The fixtures are the bytes released builds (wire v4, 26.10.0 on) send for
/// one message of each type. Their parsers are strict, so a message they
/// know must keep exactly these bytes. Change an encoding and this fails:
/// add a new message type, or a caps bit (§3.8), instead.
@Suite struct WireCompatTests {
    static let control = [
        "010b047c0b78074001710e0000",
        "020b041100000004be05bc0302",
        "0308d20400000a00ff03",
        "0410080706050403020140420f0000000000",
        "0518080706050403020140420f00000000003a430f0000000000",
        "06104d000000000080007c0b4006000040ff",
        "07124d000000020003008403feca0df0efbeadde",
        "080101",
        "09042a000000",
        "0a0c630000000300010002000300",
        "0b058002900101",
        "0c110200010000000000020102030405060708",
        "0d0601be05bc0302",
        "0f060168656c6c6f",
        "1003640101",
        "0e0d057c0000000000180000000000",
        "111e010007000000054e6f7465730947726f6365726965730102000200020909",
        "120407000000",
        "13050220035802",
        "14160a7669657765722e6c6f670000000003000000414243",
        "150668c3a96c6c6f",
        "16080106436c61756465",
        "170a0500000007000000c800",
        "180705000000007b7d",
        "19080006706175736564",
        "1a0b4d6163426f6f6b20416972",
        "1b050109000000",
    ]
    static let video = [
        "01120102000000000000000005d0020103010203",
        "02170102000000030000000140e20100000000000000000001",
        "030701020000000405",
        "041308000000000000004000400001020201020103",
        "050701020000000607",
    ]
    static let signInRequest = "010204616c6578020070770b4d6163426f6f6b20416972"
    static let signInResponse = "01040000"

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    @Test func everyTypeIsPinned() {
        #expect(WireCompatSamples.control.count == Self.control.count)
        #expect(Set(Self.control.map { Self.bytes($0)[0] }) == Set(UInt8(0x01)...UInt8(0x1B)),
                "a control type without a fixture; add one")
        #expect(WireCompatSamples.video.count == Self.video.count)
    }

    /// This build sends what released builds expect…
    @Test func encodingsAreUnchanged() {
        for (m, hex) in zip(WireCompatSamples.control, Self.control) {
            #expect(m.encoded() == Self.bytes(hex), "\(m)")
        }
        for (m, hex) in zip(WireCompatSamples.video, Self.video) {
            #expect(m.encodedForSend() == Self.bytes(hex), "\(m)")
        }
        #expect(WireCompatSamples.signInRequest.encoded() == Self.bytes(Self.signInRequest))
        #expect(WireCompatSamples.signInResponse.encoded() == Self.bytes(Self.signInResponse))
    }

    /// …and understands what they send.
    @Test func releasedMessagesParse() {
        for (m, hex) in zip(WireCompatSamples.control, Self.control) {
            var d = ControlDeframer()
            d.append(Self.bytes(hex))
            #expect(d.next() == .message(m))
        }
        for (m, hex) in zip(WireCompatSamples.video, Self.video) {
            var d = VideoDeframer()
            d.append(Self.bytes(hex))
            #expect(d.next() == .message(m))
        }
        #expect(SignInRequest.parse(Self.bytes(Self.signInRequest)) == WireCompatSamples.signInRequest)
        #expect(SignInResponse.parse(Self.bytes(Self.signInResponse)) == WireCompatSamples.signInResponse)
    }

    /// A newer peer's message types are skipped, and the stream carries on.
    @Test func unknownTypesAreSkipped() {
        var d = ControlDeframer()
        d.append([0x7F, 0x03, 1, 2, 3] + Self.bytes(Self.control[8]))
        #expect(d.next() == .skippedUnknown(type: 0x7F))
        #expect(d.next() == .message(WireCompatSamples.control[8]))
        #expect(!d.isMalformed)
    }

    /// A newer peer's fields appended to a fixed-layout message are ignored.
    @Test func appendedFieldsAreIgnored() {
        let hello = WireCompatSamples.control[0]
        var frame = hello.encoded()
        frame[1] += 2 // the one-byte length
        var d = ControlDeframer()
        d.append(frame + [0xAB, 0xCD])
        #expect(d.next() == .message(hello))
        #expect(!d.isMalformed)
        #expect(SignInRequest.parse(Self.bytes(Self.signInRequest) + [0, 0]) == WireCompatSamples.signInRequest)
        #expect(SignInResponse.parse(Self.bytes(Self.signInResponse) + [0, 0]) == WireCompatSamples.signInResponse)
    }
}
