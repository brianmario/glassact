import Foundation

/// Key names → macOS virtual key codes and modifier flags, for agents.
/// Accepts the names computer-use agents send (xdotool style: "Return",
/// "ctrl+s", "Page_Down", "super+c") and plain ones ("enter", "cmd+shift+t",
/// "pagedown"): case-insensitive, `_`/`-` ignored inside a name, `+` joins.
/// Codes are the ANSI layout's (both ends are Macs, so they match the
/// host's keyboard positions; text goes through TEXT_INPUT instead).
public enum KeyMap {
    public struct Modifier: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let shift = Modifier(rawValue: 1 << 0)
        public static let control = Modifier(rawValue: 1 << 1)
        public static let option = Modifier(rawValue: 1 << 2)
        public static let command = Modifier(rawValue: 1 << 3)
        public static let function = Modifier(rawValue: 1 << 4)

        /// CGEventFlags bits.
        public var eventFlags: UInt32 {
            var f: UInt32 = 0
            if contains(.shift) { f |= 0x0002_0000 }
            if contains(.control) { f |= 0x0004_0000 }
            if contains(.option) { f |= 0x0008_0000 }
            if contains(.command) { f |= 0x0010_0000 }
            if contains(.function) { f |= 0x0080_0000 }
            return f
        }

        /// The modifier's own key, for pressing it like a keyboard does.
        public var keyCode: UInt16? {
            switch self {
            case .command: 55
            case .shift: 56
            case .option: 58
            case .control: 59
            case .function: 63
            default: nil
            }
        }

        /// Press order: the one physical keyboards produce.
        public static let order: [Modifier] = [.control, .option, .shift, .command, .function]
    }

    /// A parsed combination: modifiers plus one key (nil = modifiers alone,
    /// e.g. "shift" held for a shift-click).
    public struct Combo: Equatable, Sendable {
        public var modifiers: Modifier
        public var keyCode: UInt16?
        public init(modifiers: Modifier, keyCode: UInt16?) {
            self.modifiers = modifiers
            self.keyCode = keyCode
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case twoKeys(String)
        public var description: String {
            switch self {
            case .empty: "no key given"
            case let .unknownKey(name): "unknown key “\(name)”"
            case let .twoKeys(combo): "“\(combo)” names more than one non-modifier key — send them separately"
            }
        }
    }

    public static func parse(_ combo: String) throws(ParseError) -> Combo {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself, and combos ending in it ("cmd++").
        var names: [String] = []
        var i = 0
        while i < parts.count {
            if parts[i].isEmpty {
                if i + 1 < parts.count, parts[i + 1].isEmpty { names.append("+"); i += 2; continue }
                if i == parts.count - 1, !names.isEmpty { names.append("+"); i += 1; continue }
                i += 1
                continue
            }
            names.append(parts[i])
            i += 1
        }
        guard !names.isEmpty else { throw .empty }
        var result = Combo(modifiers: [], keyCode: nil)
        for raw in names {
            let name = normalize(raw)
            if let mod = modifiers[name] {
                result.modifiers.insert(mod)
                continue
            }
            guard let (code, shifted) = key(named: name, raw: raw) else { throw .unknownKey(raw) }
            guard result.keyCode == nil else { throw .twoKeys(combo) }
            result.keyCode = code
            if shifted { result.modifiers.insert(.shift) }
        }
        return result
    }

    /// The key that types `ch` on a US layout, with shift if needed — the
    /// fallback for hosts without TEXT_INPUT. Nil for anything else.
    public static func keystroke(for ch: Character) -> (code: UInt16, shift: Bool)? {
        if ch == "\n" || ch == "\r" { return (36, false) }
        if ch == "\t" { return (48, false) }
        guard let a = ch.asciiValue else { return nil }
        let s = String(UnicodeScalar(a))
        if let code = characters[s] { return (code, false) }
        if let base = shiftedCharacters[s], let code = characters[base] { return (code, true) }
        let lower = s.lowercased()
        if lower != s, let code = characters[lower] { return (code, true) }
        return nil
    }

    static func normalize(_ name: String) -> String {
        let lower = name.lowercased()
        guard lower.count > 1 else { return lower }
        return lower.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    private static func key(named name: String, raw: String) -> (UInt16, Bool)? {
        if let code = named[name] { return (code, false) }
        if raw.count == 1, let ch = raw.first, let k = keystroke(for: ch) { return (k.code, k.shift) }
        return nil
    }

    private static let modifiers: [String: Modifier] = [
        "cmd": .command, "command": .command, "super": .command, "meta": .command, "win": .command,
        "ctrl": .control, "control": .control,
        "alt": .option, "option": .option, "opt": .option,
        "shift": .shift,
        "fn": .function,
    ]

    private static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "kpenter": 76, "tab": 48, "space": 49,
        "backspace": 51, "delete": 51, "forwarddelete": 117, "del": 117,
        "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "prior": 116, "next": 121,
        "capslock": 57, "help": 114, "insert": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "minus": 27, "equal": 24, "equals": 24, "plus": 24, "bracketleft": 33, "leftbracket": 33,
        "bracketright": 30, "rightbracket": 30, "backslash": 42, "semicolon": 41,
        "apostrophe": 39, "quote": 39, "comma": 43, "period": 47, "slash": 44,
        "grave": 50, "backtick": 50, "volumeup": 72, "volumedown": 73, "mute": 74,
    ]

    private static let characters: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49,
    ]

    private static let shiftedCharacters: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
}
