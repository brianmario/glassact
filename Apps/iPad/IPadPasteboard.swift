import GlassActSession
import UIKit

/// The iPad's clipboard in a session: the host's copies arrive here; nothing
/// goes back on its own. Reading the clipboard on iPadOS asks the person
/// every time, so sending this device's clipboard waits for them to ask
/// (Paste to Mac, which reads it once in response to their tap).
final class IPadPasteboard: ViewerPasteboard {
    var changeCount: Int { MainActor.assumeIsolated { UIPasteboard.general.changeCount } }

    func shareableText() -> String? { nil }

    func setText(_ text: String) {
        MainActor.assumeIsolated { UIPasteboard.general.string = text }
    }
}
