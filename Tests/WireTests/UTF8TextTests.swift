import Testing
import GlassActWire

/// Wire text is valid UTF-8 or refused (INV-6). `strictString` is the path
/// below macOS 15, which CI (macOS 27) never takes, so it's checked here
/// directly, against the same vectors as the OS's own check.
@Suite struct UTF8TextTests {
    static let valid: [[UInt8]] = [
        [],
        Array("hello".utf8),
        Array("é ü ß ⌘ 漢字 🙂".utf8),
        [0xEF, 0xBF, 0xBD],             // U+FFFD itself is valid text
        [0x00, 0x7F],                   // NUL and DEL are valid UTF-8
        [0xF4, 0x8F, 0xBF, 0xBF],       // U+10FFFF, the last scalar
    ]
    static let invalid: [[UInt8]] = [
        [0xFF],                         // never valid
        [0x80],                         // a lone continuation byte
        [0xC3],                         // truncated two-byte sequence
        [0xE2, 0x8C],                   // truncated three-byte sequence
        [0xC0, 0xAF],                   // overlong "/"
        [0xE0, 0x80, 0xAF],             // overlong "/"
        [0xED, 0xA0, 0x80],             // a UTF-16 surrogate (U+D800)
        [0xF4, 0x90, 0x80, 0x80],       // past U+10FFFF
        Array("ok".utf8) + [0xFE] + Array("ok".utf8),
    ]

    @Test(arguments: valid)
    func validTextDecodes(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            #expect(UTF8Text.strictString(raw).map { Array($0.utf8) } == bytes)
            #expect(UTF8Text.string(raw).map { Array($0.utf8) } == bytes)
        }
    }

    @Test(arguments: invalid)
    func invalidTextIsRefused(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in
            #expect(UTF8Text.strictString(raw) == nil)
            #expect(UTF8Text.string(raw) == nil)
        }
    }
}
