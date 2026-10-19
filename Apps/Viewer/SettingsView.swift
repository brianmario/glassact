import AppKit
import GlassActTransport
import SwiftUI

/// Glass Act Viewer › Settings…: what applies to every connection.
struct SettingsView: View {
    @Bindable var settings: ViewerSettings
    let viewerFingerprint: String
    let knownHosts: KnownHosts
    let nearby: NearbyHosts
    @State private var clipboard = NSPasteboard.general.accessBehavior
    @State private var hosts: [(key: String, fingerprint: String)] = []
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Picker("When the network is slow", selection: $settings.qualityFloor) {
                    Text("Adjust Quality Automatically").tag(0)
                    Divider()
                    Text("Keep Quality High").tag(1)
                    Text("Keep Quality Medium").tag(2)
                    Text("Keep Quality Low").tag(3)
                }
                Toggle("Prefer sharpness over smooth motion", isOn: $settings.preferSharpness)
            } header: {
                Text("Picture")
            } footer: {
                Text("Keeping quality high holds text crisp on a slow network, at the cost of fewer frames "
                     + "per second. Preferring sharpness also keeps moving content sharper whenever the "
                     + "network has room to spare, using more bandwidth. Changes apply the next time you "
                     + "connect.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Local Network") {
                    if nearby.isBlocked {
                        Button("Open Settings…") { NearbyHosts.openPrivacySettings() }
                    } else {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                LabeledContent("Clipboard") {
                    if clipboard == .alwaysAllow {
                        Label("Always Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack(spacing: 8) {
                            Text(clipboard == .alwaysDeny ? "Off" : "Asks Each Time")
                                .foregroundStyle(.secondary)
                            Button("Open Settings…") { NearbyHosts.openPrivacySettings("Privacy_Pasteboard") }
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text(clipboard == .alwaysDeny
                     ? "Clipboard sharing is off: copies on either Mac won’t reach the other. Choose Always Allow "
                        + "for Glass Act Viewer under Paste from Other Apps."
                     : "Local Network lets Glass Act Viewer find and reach Macs nearby. For clipboard sharing, choose "
                        + "Always Allow under Paste from Other Apps so macOS doesn’t ask on every copy.")
                    .settingsFooter()
            }

            Section {
                Toggle("Allow agents to use this session", isOn: $settings.allowAgents)
            } header: {
                Text("Agents")
            } footer: {
                Text("Lets AI agents on this Mac — the glassact command, or an MCP client like Claude — see and use "
                     + "the Mac you’re connected to, through this window. You’ll see when one is active, your own "
                     + "input always comes first, and Connection › Stop Agent ends it. "
                     + "Connect one with: glassact mcp (attach_viewer), or glassact --session viewer …")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Viewer ID") {
                    HStack(spacing: 8) {
                        Text(viewerFingerprint.isEmpty ? "Unavailable" : Self.abbreviated(viewerFingerprint))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(viewerFingerprint)
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewerFingerprint, forType: .string)
                            copied = true
                        }
                        .disabled(viewerFingerprint.isEmpty)
                    }
                }
            } header: {
                Text("This Viewer")
            } footer: {
                Text("A host asks its user to approve this viewer the first time you connect.")
                    .settingsFooter()
            }

            Section {
                if hosts.isEmpty {
                    Text("No hosts yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hosts, id: \.key) { entry in
                        LabeledContent {
                            Button("Forget") { forget(entry.key) }
                        } label: {
                            Text(entry.key)
                            Text(Self.abbreviated(entry.fingerprint))
                                .font(.caption.monospaced())
                        }
                    }
                }
            } header: {
                Text("Known Hosts")
            } footer: {
                Text("Glass Act remembers each host’s key after the first connection, and won’t connect if it "
                     + "changes. Forget a host whose key changed for a reason you know about.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .frame(minHeight: 430)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
    }

    private func reload() {
        hosts = knownHosts.all
        clipboard = NSPasteboard.general.accessBehavior
        copied = false
    }

    private func forget(_ key: String) {
        try? knownHosts.forget(key: key)
        withAnimation { reload() }
    }

    /// "e6c9 2d22 cb33 … 8c13 6390".
    static func abbreviated(_ fp: String) -> String {
        guard fp.count > 24 else { return fp }
        func groups(_ s: Substring) -> String {
            stride(from: 0, to: s.count, by: 4).map { i -> String in
                let lo = s.index(s.startIndex, offsetBy: i)
                return String(s[lo..<s.index(lo, offsetBy: min(4, s.count - i))])
            }.joined(separator: " ")
        }
        return groups(fp.prefix(12)) + " … " + groups(fp.suffix(8))
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
