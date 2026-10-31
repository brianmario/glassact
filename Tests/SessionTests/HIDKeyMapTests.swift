import Testing
@testable import GlassActSession

/// The iPad's HID usages to macOS key codes: the typing keys must agree
/// with the agent key map (one US layout, two routes in), and the keys that
/// carry flags of their own must carry them.
@Suite struct HIDKeyMapTests {
    /// HID usage → the character it types on a US keyboard, unshifted.
    static let usTyping: [(Int, Character)] = {
        var keys: [(Int, Character)] = []
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() { keys.append((0x04 + i, ch)) }
        for (i, ch) in "1234567890".enumerated() { keys.append((0x1E + i, ch)) }
        let punctuation: [(Int, Character)] = [
            (0x2C, " "), (0x2D, "-"), (0x2E, "="), (0x2F, "["), (0x30, "]"), (0x31, "\\"), (0x33, ";"),
            (0x34, "'"), (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"), (0x28, "\n"), (0x2B, "\t"),
        ]
        return keys + punctuation
    }()

    @Test func typingKeysAgreeWithTheAgentKeyMap() throws {
        for (usage, ch) in Self.usTyping {
            let key = try #require(HIDKeyMap.key(usage: usage), "usage 0x\(String(usage, radix: 16))")
            let agent = try #require(KeyMap.keystroke(for: ch))
            #expect(key.code == agent.code && !agent.shift, "“\(ch)”: HID → \(key.code), agent map → \(agent.code)")
            #expect(key.flags == 0)
        }
    }

    @Test func navigationAndFunctionKeysCarryTheirFlags() throws {
        let left = try #require(HIDKeyMap.key(usage: 0x50))
        #expect(left == .init(code: 0x7B, flags: HIDKeyMap.function | HIDKeyMap.numericPad))
        #expect(HIDKeyMap.key(usage: 0x3A) == .init(code: 0x7A, flags: HIDKeyMap.function)) // F1
        #expect(HIDKeyMap.key(usage: 0x45) == .init(code: 0x6F, flags: HIDKeyMap.function)) // F12
        #expect(HIDKeyMap.key(usage: 0x4C) == .init(code: 0x75, flags: HIDKeyMap.function)) // forward delete
        #expect(HIDKeyMap.key(usage: 0x58) == .init(code: 0x4C, flags: HIDKeyMap.numericPad)) // keypad enter
    }

    @Test func modifiersAreTheMacsOwnKeys() {
        let sides: [(Int, UInt16)] = [(0xE0, 59), (0xE1, 56), (0xE2, 58), (0xE3, 55),
                                      (0xE4, 62), (0xE5, 60), (0xE6, 61), (0xE7, 54)]
        for (usage, code) in sides {
            #expect(HIDKeyMap.key(usage: usage)?.code == code)
            #expect(HIDKeyMap.isModifier(usage: usage))
        }
        #expect(!HIDKeyMap.isModifier(usage: 0x04))
    }

    @Test func unknownUsagesAreNil() {
        #expect(HIDKeyMap.key(usage: 0) == nil)
        #expect(HIDKeyMap.key(usage: 0x01) == nil) // error roll-over
        #expect(HIDKeyMap.key(usage: 0xFF) == nil)
    }
}
