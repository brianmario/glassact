import Testing
import GlassActCore

/// Clipboard sync leaves marked items alone (§13): a password manager's
/// concealed, transient or generated copy stays on its own Mac.
@Suite struct ClipboardSyncTests {
    @Test func plainTextIsShared() {
        #expect(ClipboardSync.mayShare(types: ["public.utf8-plain-text", "NSStringPboardType"]))
    }

    @Test func markedItemsAreNot() {
        for marker in ClipboardSync.privateTypes {
            #expect(!ClipboardSync.mayShare(types: ["public.utf8-plain-text", marker]), "\(marker)")
        }
    }
}
