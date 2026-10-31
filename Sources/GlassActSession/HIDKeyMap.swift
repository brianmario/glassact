/// An iPad's hardware keyboard to the host's keys (§3.5 INPUT kinds 5/6).
///
/// iPadOS reports a key as its USB HID usage (keyboard page 0x07, what
/// `UIKey.keyCode` holds); the host posts macOS virtual key codes (`kVK_*`).
/// Both name the physical key, not the character, so the host's own input
/// source decides what a key types, as with the Mac Viewer.
public enum HIDKeyMap {
    public struct Key: Equatable, Sendable {
        /// The macOS virtual key code.
        public let code: UInt16
        /// Flags the key carries itself (`KeyModifiers` layout): numeric pad
        /// for arrows and keypad keys, function for arrows, function keys and
        /// the navigation block, as a Mac keyboard's own events have them.
        public let flags: UInt32
    }

    static let numericPad: UInt32 = 1 << 21
    static let function: UInt32 = 1 << 23

    /// The key for HID usage `usage`, or nil for keys a Mac has no code for.
    public static func key(usage: Int) -> Key? {
        guard let entry = table[usage] else { return nil }
        return Key(code: entry.code, flags: entry.flags)
    }

    /// Whether `usage` is a modifier key (control, shift, option, command,
    /// either side): the host tracks those as held keys.
    public static func isModifier(usage: Int) -> Bool { (0xE0...0xE7).contains(usage) }

    private static let table: [Int: (code: UInt16, flags: UInt32)] = {
        var t: [Int: (code: UInt16, flags: UInt32)] = [:]
        // a–z (HID 0x04–0x1D), in alphabetical order.
        let letters: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, code) in letters.enumerated() { t[0x04 + i] = (code, 0) }
        // 1–9, then 0 (HID 0x1E–0x27).
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, code) in digits.enumerated() { t[0x1E + i] = (code, 0) }
        let plain: [Int: UInt16] = [
            0x28: 0x24, // return
            0x29: 0x35, // escape
            0x2A: 0x33, // delete (backspace)
            0x2B: 0x30, // tab
            0x2C: 0x31, // space
            0x2D: 0x1B, // -
            0x2E: 0x18, // =
            0x2F: 0x21, // [
            0x30: 0x1E, // ]
            0x31: 0x2A, // \
            0x32: 0x2A, // non-US # (ISO): the Mac's backslash position
            0x33: 0x29, // ;
            0x34: 0x27, // '
            0x35: 0x32, // `
            0x36: 0x2B, // ,
            0x37: 0x2F, // .
            0x38: 0x2C, // /
            0x39: 0x39, // caps lock
            0x64: 0x0A, // non-US \ (ISO section)
            0x7F: 0x4A, // mute
            0x80: 0x48, // volume up
            0x81: 0x49, // volume down
            0x87: 0x5E, // international 1: JIS underscore
            0x89: 0x5D, // international 3: JIS yen
            0x90: 0x68, // LANG1: JIS kana
            0x91: 0x66, // LANG2: JIS eisu
            0xE0: 0x3B, // left control
            0xE1: 0x38, // left shift
            0xE2: 0x3A, // left option
            0xE3: 0x37, // left command
            0xE4: 0x3E, // right control
            0xE5: 0x3C, // right shift
            0xE6: 0x3D, // right option
            0xE7: 0x36, // right command
        ]
        for (usage, code) in plain { t[usage] = (code, 0) }
        // F1–F12 (HID 0x3A–0x45), F13–F20 (HID 0x68–0x6F).
        let fKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in fKeys.enumerated() { t[0x3A + i] = (code, function) }
        let fHigh: [UInt16] = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, code) in fHigh.enumerated() { t[0x68 + i] = (code, function) }
        let navigation: [Int: UInt16] = [
            0x49: 0x72, // insert → help
            0x4A: 0x73, // home
            0x4B: 0x74, // page up
            0x4C: 0x75, // forward delete
            0x4D: 0x77, // end
            0x4E: 0x79, // page down
        ]
        for (usage, code) in navigation { t[usage] = (code, function) }
        let arrows: [Int: UInt16] = [0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E] // → ← ↓ ↑
        for (usage, code) in arrows { t[usage] = (code, function | numericPad) }
        let keypad: [Int: UInt16] = [
            0x53: 0x47, // num lock → clear
            0x54: 0x4B, // /
            0x55: 0x43, // *
            0x56: 0x4E, // -
            0x57: 0x45, // +
            0x58: 0x4C, // enter
            0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, // 1–5
            0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52, // 6–9, 0
            0x63: 0x41, // .
            0x67: 0x51, // =
            0x85: 0x5F, // keypad comma (JIS)
        ]
        for (usage, code) in keypad { t[usage] = (code, numericPad) }
        return t
    }()
}
