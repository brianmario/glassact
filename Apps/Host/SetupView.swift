import AppKit
import SwiftUI

/// First launch, and whenever something it needs gets turned off: one
/// window that walks through each macOS permission, checks itself off live
/// as the user grants them, and says plainly what won't work without each.
struct SetupView: View {
    let permissions: HostPermissions
    /// The window was reopened because something that was on went off.
    let isRecheck: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text(isRecheck ? "Glass Act Host Needs Your Attention" : "Set Up Glass Act Host")
                    .font(.title2.weight(.semibold))
                Text(isRecheck
                     ? "Some permissions Glass Act Host uses were turned off. Viewers won’t work fully until they’re back on."
                     : "Glass Act Host shares this Mac’s screen with Glass Act Viewer. Give it these permissions now, "
                        + "so the first viewer just works.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 26)
            .padding(.bottom, 20)

            Card {
                PermissionRow(symbol: "rectangle.dashed.badge.record", title: HostPermissions.PaneName.screenRecording,
                              detail: "Lets viewers see this screen. Required.",
                              state: screenState, action: screenAction)
                Divider().padding(.leading, 54)
                PermissionRow(symbol: "hand.point.up.left.fill", title: HostPermissions.PaneName.deviceControl,
                              detail: "Lets viewers use this Mac’s mouse and keyboard. Required for control.",
                              state: permissions.accessibility ? .granted("Allowed") : .needed("Allow…"),
                              action: permissions.requestAccessibility)
                Divider().padding(.leading, 54)
                PermissionRow(symbol: "network", title: HostPermissions.PaneName.localNetwork,
                              detail: "Lets viewers on this network find and reach this Mac. Recommended.",
                              state: localNetworkState, action: permissions.requestLocalNetwork)
                Divider().padding(.leading, 54)
                PermissionRow(symbol: "doc.on.clipboard", title: HostPermissions.PaneName.clipboard,
                              detail: clipboardDetail, state: clipboardState, action: permissions.requestClipboard)
            }

            HStack {
                Text("You can change these anytime in System Settings › Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(permissions.requiredGranted ? "Done" : "Not Now", action: onDone)
                    .keyboardShortcut(permissions.requiredGranted ? .defaultAction : .cancelAction)
                    .buttonStyle(.borderedProminent)
                    .tint(permissions.requiredGranted ? .accentColor : .gray)
                    .controlSize(.large)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.25), value: permissions.screenRecording)
        .animation(.smooth(duration: 0.25), value: permissions.accessibility)
        .animation(.smooth(duration: 0.25), value: permissions.localNetwork)
        .animation(.smooth(duration: 0.25), value: permissions.clipboard)
        .animation(.smooth(duration: 0.25), value: permissions.captureNeedsRelaunch)
    }

    // MARK: - Row states

    private var screenState: PermissionRow.State {
        if !permissions.screenRecordingAvailable {
            return .unavailable("Not allowed on this Mac")
        }
        if permissions.captureNeedsRelaunch {
            return .restart("Restart Glass Act Host")
        }
        return permissions.screenRecording ? .granted("Allowed") : .needed("Allow…")
    }

    private func screenAction() {
        if permissions.captureNeedsRelaunch {
            HostPermissions.relaunch()
        } else {
            permissions.requestScreenRecording()
        }
    }

    private var localNetworkState: PermissionRow.State {
        switch permissions.localNetwork {
        case .allowed: .granted("Allowed")
        case .blocked: .needed("Open Settings…")
        case .unknown: .needed("Allow…")
        }
    }

    private var clipboardState: PermissionRow.State {
        switch permissions.clipboard {
        case .alwaysAllow: .granted("Always Allowed")
        case .default: .needed("Allow…")
        default: .needed("Open Settings…")
        }
    }

    private var clipboardDetail: String {
        switch permissions.clipboard {
        case .ask: "Clipboard sync: copy here, paste on the viewer. Set to Always Allow so macOS doesn’t ask on every copy."
        case .alwaysDeny: "Clipboard sync: copy here, paste on the viewer. Turned off, so copies won’t reach viewers."
        default: "Clipboard sync: copy here, paste on the viewer — and the other way around. Recommended."
        }
    }
}

private struct PermissionRow: View {
    enum State: Equatable {
        case granted(String)
        case needed(String)
        case restart(String)
        /// Nothing the user can switch on here (a device-management policy).
        case unavailable(String)
    }

    let symbol: String
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(iconTint.gradient, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .unavailable = state {
                    Text("This Mac’s administrator doesn’t allow screen recording, so Glass Act Host can’t share it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .restart = state {
                    Text("Turned it on? macOS applies it the next time Glass Act Host opens.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            switch state {
            case let .granted(label):
                Label(label, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            case let .needed(label):
                Button(label, action: action)
                    .controlSize(.regular)
            case let .restart(label):
                Button(label, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            case let .unavailable(label):
                Label(label, systemImage: "nosign")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var iconTint: Color {
        if case .granted = state { return .green }
        return .accentColor
    }
}

/// A grouped-list section, like System Settings.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
