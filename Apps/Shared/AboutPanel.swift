import AppKit

/// The standard About panel, shared by both apps: the app's tagline, then
/// the notices a binary distribution must carry — Glass Act's MIT license
/// and the vendored libwebp's BSD-3-Clause license and patent grant. They
/// live in `Acknowledgements.txt` (bundled into both apps from this folder);
/// a line starting `# ` is a heading.
@MainActor
enum AboutPanel {
    static func show(tagline: String) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits(tagline: tagline),
            .version: BuildInfo.aboutVersion, // the build number and commit
        ])
    }

    static func credits(tagline: String) -> NSAttributedString {
        let size = NSFont.smallSystemFontSize
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSMutableAttributedString(string: tagline, attributes: body)
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let notices = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Acknowledgements.txt is missing from the app bundle")
            return text
        }
        text.append(NSAttributedString(string: "\n\n", attributes: body))
        let lines = notices.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n", attributes: body)) }
            if line.hasPrefix("# ") {
                text.append(NSAttributedString(string: String(line.dropFirst(2)), attributes: heading))
            } else {
                text.append(NSAttributedString(string: String(line), attributes: body))
            }
        }
        return text
    }
}
