import Testing
@testable import GlassActCore

/// Modifier keys as the Viewer forwards them: each flags-changed event names
/// one key, and whether it went down or up comes from that key's own bit.
@Suite struct KeyModifiersTests {
    // NSEvent raw flags as a keyboard sends them: device-independent plus
    // the left/right device bit.
    static let lCmd: UInt = KeyModifiers.command | 0x08
    static let rCmd: UInt = KeyModifiers.command | 0x10
    static let lOpt: UInt = KeyModifiers.option | 0x20
    static let lShift: UInt = KeyModifiers.shift | 0x02

    @Test func pressingAndReleasingOneModifier() {
        #expect(KeyModifiers.isDown(keyCode: 55, modifierFlags: Self.lCmd) == true)
        #expect(KeyModifiers.isDown(keyCode: 55, modifierFlags: 0) == false)
    }

    /// ⌘⌥→ then releasing ⌥ first: ⌥ goes up although ⌘ is still held.
    @Test func releasingOneModifierWhileAnotherIsHeld() {
        #expect(KeyModifiers.isDown(keyCode: 58, modifierFlags: Self.lCmd | Self.lOpt) == true)
        #expect(KeyModifiers.isDown(keyCode: 58, modifierFlags: Self.lCmd) == false)
        #expect(KeyModifiers.isDown(keyCode: 55, modifierFlags: 0) == false)
    }

    /// Both ⌘ keys held, then the left one released.
    @Test func leftAndRightAreTrackedApart() {
        #expect(KeyModifiers.isDown(keyCode: 55, modifierFlags: Self.rCmd) == false)
        #expect(KeyModifiers.isDown(keyCode: 54, modifierFlags: Self.rCmd) == true)
    }

    /// No device bits (a synthetic event): the side-less flag decides.
    @Test func withoutDeviceBits() {
        #expect(KeyModifiers.isDown(keyCode: 56, modifierFlags: KeyModifiers.shift) == true)
        #expect(KeyModifiers.isDown(keyCode: 60, modifierFlags: KeyModifiers.command) == false)
    }

    @Test func capsLockAndFunction() {
        #expect(KeyModifiers.isDown(keyCode: 57, modifierFlags: KeyModifiers.capsLock) == true)
        #expect(KeyModifiers.isDown(keyCode: 57, modifierFlags: 0) == false)
        #expect(KeyModifiers.isDown(keyCode: 63, modifierFlags: KeyModifiers.function) == true)
        #expect(KeyModifiers.isDown(keyCode: 63, modifierFlags: Self.lShift) == false)
    }

    @Test func notAModifierKey() {
        #expect(KeyModifiers.isDown(keyCode: 124, modifierFlags: Self.lCmd) == nil)
    }

    /// An arrow keeps its numeric-pad and function flags; device bits and
    /// help are dropped.
    @Test func forwardedFlags() {
        let arrow = Self.lCmd | Self.lOpt | KeyModifiers.numericPad | KeyModifiers.function | (1 << 22)
        #expect(KeyModifiers.forwarded(arrow)
            == UInt32(KeyModifiers.command | KeyModifiers.option | KeyModifiers.numericPad | KeyModifiers.function))
    }
}
