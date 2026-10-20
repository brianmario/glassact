import AppKit
import GlassActTransport
import SwiftUI

/// What the approved-viewers window shows, refreshed whenever the list
/// changes (and every few seconds while open, for "connected now" and the
/// relative times).
@MainActor @Observable
final class ApprovedViewersModel {
    private(set) var entries: [AuthorizedViewers.Entry] = []
    private(set) var connected: String?
    @ObservationIgnored let controller: HostController

    init(controller: HostController) {
        self.controller = controller
        reload()
    }

    func reload() {
        let fresh = controller.authorizedViewers.all
        if fresh != entries { entries = fresh }
        let now = controller.connectedViewerFingerprint
        if now != connected { connected = now }
    }

    var viewers: [AuthorizedViewers.Entry] { entries.filter { $0.kind != .agent } }
    var agents: [AuthorizedViewers.Entry] { entries.filter { $0.kind == .agent } }
}

/// Options › Approved Viewers…: everything that connects without asking —
/// people's viewers and agents apart — with a name for each, and a way to
/// rename, limit or forget any one of them.
struct ApprovedViewersView: View {
    @Bindable var model: ApprovedViewersModel
    @State private var renaming: AuthorizedViewers.Entry?
    @State private var newName = ""
    @State private var forgetting: AuthorizedViewers.Entry?
    @State private var forgettingAll = false
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Approved Viewers", systemImage: "person.2.slash")
                    } description: {
                        Text("The first time a viewer or an agent connects, Glass Act Host asks you to approve it. "
                             + "Approved ones appear here.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    Form {
                        if !model.viewers.isEmpty {
                            Section {
                                ForEach(model.viewers, id: \.fingerprint) { row($0) }
                            } header: {
                                Text("Viewers")
                            } footer: {
                                Text("People using Glass Act Viewer on another Mac.").settingsFooter()
                            }
                        }
                        if !model.agents.isEmpty {
                            Section {
                                ForEach(model.agents, id: \.fingerprint) { row($0) }
                            } header: {
                                Text("Agents")
                            } footer: {
                                Text("Programs driving this Mac on their own. View Only lets one watch without "
                                     + "using the mouse or keyboard.").settingsFooter()
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
            }

            Divider()
            HStack {
                Button("Forget All…", role: .destructive) { forgettingAll = true }
                    .disabled(model.entries.isEmpty)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .frame(minHeight: 320)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let entry = renaming { model.controller.renameViewer(entry.fingerprint, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("A name for this \(renaming?.kind == .agent ? "agent" : "viewer") on this Mac. "
                 + "Leave it empty to use the name it reports.")
        }
        .confirmationDialog(forgetTitle, isPresented: Binding(get: { forgetting != nil },
                                                              set: { if !$0 { forgetting = nil } })) {
            Button(forgetting?.kind == .agent ? "Forget Agent" : "Forget Viewer", role: .destructive) {
                if let entry = forgetting { model.controller.forgetViewer(entry.fingerprint) }
                forgetting = nil
            }
        } message: {
            Text(forgetMessage)
        }
        .confirmationDialog("Forget all approved viewers and agents?", isPresented: $forgettingAll) {
            Button("Forget All", role: .destructive) { model.controller.forgetApprovedViewers() }
        } message: {
            Text("Each will need your approval again the next time it connects. One that’s connected now "
                 + "is disconnected.")
        }
    }

    private var forgetTitle: String {
        guard let entry = forgetting else { return "" }
        return "Forget “\(entry.displayName)”?"
    }

    private var forgetMessage: String {
        guard let entry = forgetting else { return "" }
        var text = entry.kind == .agent
            ? "It will need your approval again before it can see or use this Mac."
            : "It will need your approval again the next time it connects."
        if entry.fingerprint == model.connected { text += " It’s connected now and will be disconnected." }
        return text
    }

    @ViewBuilder
    private func row(_ entry: AuthorizedViewers.Entry) -> some View {
        let isAgent = entry.kind == .agent
        let isConnected = entry.fingerprint == model.connected
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background((isAgent ? Color.purple : Color.blue).gradient, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .bottomTrailing) {
                    if isConnected {
                        Circle().fill(.green)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .offset(x: 3, y: 3)
                            .accessibilityLabel("Connected now")
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).fontWeight(.medium)
                Text(entry.details(connected: isConnected))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.abbreviated(entry.fingerprint))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .help(QUICIdentity.keyString(entry.fingerprint))
            }
            Spacer(minLength: 8)
            if isAgent {
                Picker("Access", selection: Binding(
                    get: { entry.viewOnly },
                    set: { model.controller.setViewerViewOnly(entry.fingerprint, $0) })) {
                    Text("Control").tag(false)
                    Text("View Only").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Menu {
                Button("Rename…") {
                    newName = entry.name
                    renaming = entry
                }
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(QUICIdentity.keyString(entry.fingerprint), forType: .string)
                }
                Divider()
                Button(isAgent ? "Forget Agent…" : "Forget Viewer…", role: .destructive) { forgetting = entry }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(entry.displayName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// "e6c9 2d22 cb33 … 8c13 6390".
    static func abbreviated(_ fp: String) -> String { HostAppDelegate.abbreviated(fp) }
}

extension AuthorizedViewers.Entry {
    /// What to call it: the user's name, else what it reported, else where it
    /// connected from.
    var displayName: String {
        if !name.isEmpty { return name }
        if kind == .agent {
            if !label.isEmpty && label != "agent" { return label }
            return device.isEmpty ? "Agent" : "Agent on \(device)"
        }
        if !device.isEmpty { return device }
        // An address makes a poor name (a LAN viewer's is a long IPv6 one):
        // it goes in the details line instead.
        return "Viewer"
    }

    var symbol: String {
        kind == .agent ? (viewOnly ? "eye" : "cursorarrow.rays") : "laptopcomputer"
    }

    @MainActor func details(connected: Bool) -> String {
        var parts: [String] = []
        // The reported computer, when the title is something else.
        if !device.isEmpty, displayName != device {
            parts.append(kind == .agent ? "on \(device)" : device)
        }
        if !address.isEmpty { parts.append(Self.place(address)) }
        if kind != .agent, device.isEmpty, name.isEmpty {
            parts.append("named once it connects with an up-to-date Viewer")
        }
        if connected {
            parts.append("connected now")
        } else if let seen = lastSeenAt {
            parts.append("last connected " + Self.relative.localizedString(for: seen, relativeTo: Date()))
        } else if let approved = approvedAt {
            parts.append("approved " + Self.relative.localizedString(for: approved, relativeTo: Date()))
        } else {
            parts.append("not connected since this list began keeping details")
        }
        return parts.joined(separator: " · ")
    }

    /// "100.64.0.7" as is; loopback is "this Mac".
    static func place(_ address: String) -> String {
        let bare = address.split(separator: "%").first.map(String.init) ?? address
        return ["127.0.0.1", "::1", "localhost"].contains(bare) ? "this Mac" : bare
    }

    @MainActor private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

private extension View {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
