import AppKit
import GlassActCore
import GlassActSession

/// The Mac's general pasteboard, as the session syncs it (main thread).
final class MacPasteboard: ViewerPasteboard {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func shareableText() -> String? {
        let pb = NSPasteboard.general
        // Not a password manager's concealed or one-time item (§13).
        guard ClipboardSync.mayShare(types: pb.types?.map(\.rawValue) ?? []) else { return nil }
        return pb.string(forType: .string)
    }

    func setText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
