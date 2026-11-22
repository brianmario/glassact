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

    /// The Host's posted flags: ⌘ held, then V. Both events carry the left
    /// ⌘ device bit, as a keyboard's do (a VM's view reads ⌘ from it).
    @Test func postedFlagsCarryEachHeldModifiersSide() {
        let cmd = UInt32(KeyModifiers.command)
        #expect(KeyModifiers.posted(cmd, heldKeyCodes: [55]) == UInt32(Self.lCmd))
        #expect(KeyModifiers.posted(cmd, heldKeyCodes: [55, 9]) == UInt32(Self.lCmd))
        #expect(KeyModifiers.posted(cmd, heldKeyCodes: [54]) == UInt32(Self.rCmd))
        #expect(KeyModifiers.posted(cmd, heldKeyCodes: [54, 55]) == UInt32(Self.lCmd | 0x10))
        let cmdShift = UInt32(KeyModifiers.command | KeyModifiers.shift)
        #expect(KeyModifiers.posted(cmdShift, heldKeyCodes: [55, 56, 9]) == UInt32(Self.lCmd | Self.lShift))
    }

    /// ⌘'s key-up: the Viewer's flags no longer have ⌘, so no side bit
    /// either, even if the Host's set of held keys disagrees for a moment.
    /// Keys that aren't modifiers, caps lock and fn add nothing.
    @Test func postedFlagsNeverContradictTheSideLessFlags() {
        #expect(KeyModifiers.posted(0, heldKeyCodes: [55]) == 0)
        #expect(KeyModifiers.posted(0, heldKeyCodes: [9, 57, 63]) == 0)
        let fnPad = UInt32(KeyModifiers.function | KeyModifiers.numericPad)
        #expect(KeyModifiers.posted(fnPad, heldKeyCodes: [123]) == fnPad)
        // An agent's ⌘ with no ⌘ key pressed: unchanged, as before.
        #expect(KeyModifiers.posted(UInt32(KeyModifiers.command), heldKeyCodes: [9]) == UInt32(KeyModifiers.command))
    }
}
