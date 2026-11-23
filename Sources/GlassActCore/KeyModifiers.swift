/// Keyboard modifiers as the Viewer forwards them (§3.5 INPUT kinds 5/6).
///
/// Raw values are `NSEvent.ModifierFlags` / `CGEventFlags` bits, which share
/// one layout: the device-independent flags in bits 16–23, and the
/// device-dependent left/right bits below them (IOKit's `NX_DEVICE*KEYMASK`).
public enum KeyModifiers {
    // Device-independent.
    static let capsLock: UInt = 1 << 16
    static let shift: UInt = 1 << 17
    static let control: UInt = 1 << 18
    static let option: UInt = 1 << 19
    static let command: UInt = 1 << 20
    static let numericPad: UInt = 1 << 21
    static let function: UInt = 1 << 23

    /// The flags the host stamps on a key event: the modifiers held, plus
    /// numeric pad and function, which arrow, function and keypad keys carry
    /// themselves. Without those an injected ← isn't quite the key a
    /// keyboard sends.
    public static func forwarded(_ modifierFlags: UInt) -> UInt32 {
        UInt32(truncatingIfNeeded: modifierFlags & (capsLock | shift | control | option | command | numericPad | function))
    }

    /// The flags the Host posts a key event with: `forwarded` (what the
    /// Viewer sent) plus the left/right device bit of each modifier key the
    /// Host holds down (`heldKeyCodes`, Mac virtual key codes), as a
    /// keyboard's events carry them. Most apps read only the side-less
    /// flags, but a virtual machine's view (Virtualization.framework) works
    /// out which keys the guest holds from the device bits: without them it
    /// saw ⌘V as a bare V. A side's bit is set only while its side-less flag
    /// is, so the two never disagree.
    public static func posted(_ forwarded: UInt32, heldKeyCodes: Set<Int>) -> UInt32 {
        var flags = UInt(forwarded)
        for code in heldKeyCodes {
            let (bit, either): (UInt, UInt) = switch code {
            case 59: (0x0001, control)
            case 62: (0x2000, control)
            case 56: (0x0002, shift)
            case 60: (0x0004, shift)
            case 55: (0x0008, command)
            case 54: (0x0010, command)
            case 58: (0x0020, option)
            case 61: (0x0040, option)
            default: (0, 0)
            }
            if bit != 0, flags & either != 0 { flags |= bit }
        }
        return UInt32(truncatingIfNeeded: flags)
    }

    /// ⌃⌘Q, the system's Lock Screen shortcut, as a person types it: left ⌃
    /// down, left ⌘ down, Q down and up, then ⌘ and ⌃ up, each event with the
    /// flags `posted` gives the keys held at that point (the side-less flags
    /// and each side's device bit), as the Host posts remote input. The Host
    /// used to post a bare Q down/up with the ⌃⌘ flags only, and on a Mac
    /// where remote input worked that didn't lock (#166).
    public static let lockScreenKeystrokes: [(keyCode: UInt16, down: Bool, flags: UInt32)] = {
        let control = UInt32(Self.control), command = UInt32(Self.command)
        let steps: [(UInt16, Bool, UInt32, Set<Int>)] = [
            (59, true, control, [59]),
            (55, true, control | command, [59, 55]),
            (12, true, control | command, [59, 55]),
            (12, false, control | command, [59, 55]),
            (55, false, control, [59]),
            (59, false, 0, []),
        ]
        return steps.map { ($0.0, $0.1, posted($0.2, heldKeyCodes: $0.3)) }
    }()

    /// Whether the modifier key `keyCode` is down after a flags-changed
    /// event with `modifierFlags`, or nil if `keyCode` isn't a modifier key.
    ///
    /// Each side is judged by its own device bit, so releasing ⌥ while
    /// still holding ⌘, or the left ⌘ while holding the right, reads as that
    /// key going up. (Asking whether any modifier is still held read it as
    /// going down again.)
    public static func isDown(keyCode: UInt16, modifierFlags: UInt) -> Bool? {
        let bit: UInt
        switch keyCode {
        case 59: bit = 0x0001   // left control
        case 62: bit = 0x2000   // right control
        case 56: bit = 0x0002   // left shift
        case 60: bit = 0x0004   // right shift
        case 55: bit = 0x0008   // left command
        case 54: bit = 0x0010   // right command
        case 58: bit = 0x0020   // left option
        case 61: bit = 0x0040   // right option
        case 57: return modifierFlags & capsLock != 0 // the lock's state
        case 63: return modifierFlags & function != 0 // fn / 🌐
        default: return nil
        }
        if modifierFlags & 0x207F != 0 { return modifierFlags & bit != 0 }
        // No device bits (a synthetic event): fall back to the side-less flag.
        let either: UInt = switch keyCode {
        case 59, 62: control
        case 56, 60: shift
        case 55, 54: command
        default: option
        }
        return modifierFlags & either != 0
    }
}
