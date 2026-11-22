/// Wire text: the bytes as a String only when they are valid UTF-8, never a
/// repaired copy (INV-6: a peer's malformed text is refused, not patched).
public enum UTF8Text {
    /// The standard library's check where the OS has it (`String(validating:as:)`,
    /// macOS 15); `strictString` below it, on the Host's macOS 14.4 floor.
    public static func string(_ bytes: UnsafeRawBufferPointer) -> String? {
        if #available(macOS 15, iOS 18, *) {
            return unsafe String(validating: bytes, as: UTF8.self)
        }
        return unsafe strictString(bytes)
    }

    /// Before macOS 15: decode, then keep the result only if it encodes back to
    /// exactly these bytes. Decoding replaces each ill-formed sequence with
    /// U+FFFD, whose encoding (EF BF BD) is well-formed and so can never be the
    /// bytes it replaced, so any ill-formed input fails the comparison. Public
    /// so tests run it on every OS with the same vectors as `string`.
    public static func strictString(_ bytes: UnsafeRawBufferPointer) -> String? {
        let text = unsafe String(decoding: bytes, as: UTF8.self)
        return unsafe text.utf8.elementsEqual(bytes) ? text : nil
    }
}
