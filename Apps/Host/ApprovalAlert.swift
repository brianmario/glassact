import AppKit
import GlassActTransport

/// The one decision the host ever asks of its user: let this viewer in?
/// The verification code is the point of the dialog, so it's the biggest
/// thing in it — matching it against the viewer's screen is what proves no
/// one sits in between.
@MainActor
enum ApprovalAlert {
    enum Decision { case deny, allow, viewOnly }

    /// The user's answer. Agents (headless Glass Act agents name themselves in
    /// their certificate) get their own wording and a third choice: watch
    /// without control.
    static func run(code: String, viewerFingerprint: String, isAgent: Bool = false) -> Decision {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = icon(isAgent: isAgent)
        if isAgent {
            alert.messageText = "Allow an AI agent to use this Mac?"
            alert.informativeText = """
                A program is connecting as a Glass Act agent. With control, it can see this screen \
                and use its mouse and keyboard on its own — now and whenever it reconnects. While \
                it works, the menu bar shows it, your own mouse and keyboard always win, and you \
                can pause it from the Glass Act Host menu. View Only lets it watch without control.

                Allow only if the agent shows this code:
                """
        } else {
            alert.messageText = "Allow a viewer to control this Mac?"
            alert.informativeText = """
                Someone is connecting with Glass Act Viewer. Once allowed, they can see this \
                screen and use its mouse and keyboard — now and whenever they reconnect.

                Allow only if their viewer shows this code:
                """
        }
        alert.accessoryView = codeView(code: code, fingerprint: viewerFingerprint, isAgent: isAgent)
        let deny = alert.addButton(withTitle: "Don’t Allow")
        deny.keyEquivalent = "\r" // the safe answer is the default
        let allow = alert.addButton(withTitle: isAgent ? "Allow Control" : "Allow")
        allow.keyEquivalent = ""
        if isAgent { alert.addButton(withTitle: "View Only").keyEquivalent = "" }
        alert.window.initialFirstResponder = deny
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .allow
        case .alertThirdButtonReturn: return .viewOnly
        default: return .deny
        }
    }

    private static func icon(isAgent: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            .applying(.init(paletteColors: [.white, .white]))
        guard let symbol = NSImage(systemSymbolName: isAgent ? "sparkles" : "person.badge.key.fill",
                                   accessibilityDescription: isAgent ? "Agent approval" : "Viewer approval")?
            .withSymbolConfiguration(config) else { return nil }
        // The symbol on an accent-colored squircle, like a system prompt's badge.
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            let tint: NSColor = isAgent ? .systemPurple : .systemBlue
            NSGradient(starting: tint.blended(withFraction: 0.25, of: .white) ?? tint,
                       ending: tint)?.draw(in: path, angle: -90)
            let s = symbol.size
            let scale = min(40 / s.width, 40 / s.height)
            let w = s.width * scale, h = s.height * scale
            symbol.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return true
        }
    }

    private static func codeView(code: String, fingerprint: String, isAgent: Bool) -> NSView {
        let width: CGFloat = 248
        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = .monospacedSystemFont(ofSize: 19, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.isSelectable = true
        codeLabel.setAccessibilityLabel("Verification code \(code.map(String.init).joined(separator: " "))")

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(codeLabel)

        let keyLabel = NSTextField(labelWithString: "\(isAgent ? "Agent" : "Viewer") key  \(abbreviated(fingerprint))")
        keyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.alignment = .center
        keyLabel.toolTip = fingerprint
        keyLabel.isSelectable = true

        let stack = NSStackView(views: [box, keyLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: 46),
            codeLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            codeLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 72))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        return container
    }

    /// "ga1qz8fw3k5… …0d2yhqw4": enough to tell keys apart at a glance.
    private static func abbreviated(_ fp: String) -> String {
        QUICIdentity.abbreviatedKeyString(fp)
    }
}
