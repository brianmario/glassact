import AppKit
import SwiftUI

/// The connect window: pick a nearby Mac (or type an address), choose what
/// to show, connect. While a connection is in progress the same window
/// becomes its status — connecting, waiting for the host's approval (with
/// the code to compare), reconnecting — so there's always one place to look
/// and one button to cancel.
struct ConnectView: View {
    @Bindable var model: ConnectModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22) // under the transparent title bar
                .padding(.bottom, 18)
            ZStack {
                form
                    .opacity(model.phase == .idle ? 1 : 0)
                    .allowsHitTesting(model.phase == .idle)
                    .accessibilityHidden(model.phase != .idle)
                if model.phase == .signingIn {
                    SignInPanel(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if model.phase != .idle {
                    ProgressPanel(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.smooth(duration: 0.25), value: model.phase)
            footer
                .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.nearby.start() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Connect to a Mac")
                .font(.title2.weight(.semibold))
            Text("Choose a Mac running Glass Act Host, or enter its address.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .opacity(model.phase == .idle ? 1 : 0)
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let crash = model.crashNotice {
                Card {
                    CrashNoticeContent(notice: crash, onReport: model.onReportCrash, onDismiss: model.onDismissCrash)
                        .padding(12)
                }
                .transition(.opacity)
            }
            nearbySection
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Address")
                TextField("Address", text: $model.host, prompt: Text("Name or IP address"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .labelsHidden()
                    .onSubmit { if model.canConnect { model.onConnect() } }
                    .textInputSuggestions {
                        ForEach(model.addressSuggestions, id: \.self) { address in
                            Text(address).textInputCompletion(address)
                        }
                    }
            }
            optionsCard
            advanced
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: model.notice)
        .animation(.smooth(duration: 0.2), value: model.crashNotice)
        .animation(.smooth(duration: 0.2), value: model.shareMode)
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Nearby")
            Card {
                if model.nearby.isBlocked {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Glass Act Viewer can’t see your network")
                                .fontWeight(.medium)
                            Text("Turn on Local Network for Glass Act Viewer in Privacy & Security to find and reach "
                                 + "Macs nearby.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Open Settings…") { NearbyHosts.openPrivacySettings() }
                    }
                    .padding(12)
                } else if model.nearby.hosts.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs on this network…")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                } else {
                    ForEach(Array(model.nearby.hosts.enumerated()), id: \.element.id) { index, host in
                        if index > 0 { Divider().padding(.leading, 50) }
                        NearbyRow(host: host, isChosen: model.isChosen(host)) {
                            model.choose(host)
                        } onOpen: {
                            model.choose(host)
                            model.onConnect()
                        }
                    }
                }
            }
        }
    }

    private var optionsCard: some View {
        Card {
            HStack {
                Text("Show")
                Spacer()
                Picker("Show", selection: $model.shareMode) {
                    Label("Entire Display", systemImage: "display").tag(ConnectModel.ShareMode.display)
                    Label("One Window", systemImage: "macwindow").tag(ConnectModel.ShareMode.window)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            if model.shareMode == .display {
                Divider().padding(.leading, 12)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Picker("Resolution", selection: $model.resolution) {
                            ForEach(ConnectModel.Resolution.ordered) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(model.resolution.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            } else {
                Divider().padding(.leading, 12)
                Text("After connecting, choose which of the host’s windows to show. It opens here as its own window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        }
    }

    private var advanced: some View {
        DisclosureGroup(isExpanded: $model.showAdvanced) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Port").gridColumnAlignment(.trailing)
                    TextField("Port", text: $model.port, prompt: Text("4433"))
                        .labelsHidden()
                        .frame(width: 80)
                }
                GridRow {
                    Text("Host key")
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Host key", text: $model.hostKey, prompt: Text("Optional"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Text("Leave empty to trust the host’s key the first time you connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            Text("Advanced")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.smooth) { model.showAdvanced.toggle() } }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if model.phase == .idle {
                Button("Connect") { model.onConnect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canConnect)
            } else if model.phase == .signingIn {
                Button("Cancel") { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Sign In") { model.onSignIn() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canSignIn)
            } else if model.phase != .inSession {
                Button("Cancel") { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
        }
    }
}

/// The host's account, in place of the form: what a Mac's own Screen
/// Sharing asks for. The host never shows a dialog for this.
private struct SignInPanel: View {
    @Bindable var model: ConnectModel
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Sign In to “\(model.displayName)”")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Enter the name and password of the user signed in on that Mac. You only need to do this once.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                TextField("Name", text: $model.signInUser, prompt: Text("Name"))
                    .textContentType(.username)
                    .focused($focus, equals: .user)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $model.signInPassword, prompt: Text("Password"))
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { if model.canSignIn { model.onSignIn() } }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .labelsHidden()
            .disabled(model.signInBusy)
            .padding(.top, 4)
            ZStack {
                if model.signInBusy {
                    ProgressView().controlSize(.small)
                } else if let error = model.signInError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 20)
            if let key = model.signInHostKey {
                Text("First time connecting to this Mac. Its key starts \(String(key.prefix(16)).uppercased()). "
                     + "If you’re not on your own network, check it matches Glass Act Host › Copy Host Key.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = model.signInUser.isEmpty ? .user : .password }
        .onChange(of: model.signInBusy) { _, busy in
            if !busy, model.phase == .signingIn { focus = .password }
        }
    }
}

/// Connecting / approval / reconnecting, in place of the form.
private struct ProgressPanel: View {
    let model: ConnectModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            switch model.phase {
            case let .awaitingApproval(code):
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Waiting for Approval")
                    .font(.title3.weight(.semibold))
                Text("On “\(model.displayName)”, click Allow if it shows this code:")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .accessibilityLabel("Verification code \(code.map(String.init).joined(separator: " "))")
                Text("You only need to do this once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case let .reconnecting(attempt):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Reconnecting to “\(model.displayName)”…")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(attempt > 1 ? "The connection dropped. Still trying (attempt \(attempt))."
                                 : "The connection dropped. Trying again.")
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small).padding(.top, 4)
            case .loadingPicture:
                ProgressView().controlSize(.large)
                    .padding(.bottom, 4)
                Text("Loading “\(model.displayName)”’s screen…")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Connected. The picture is on its way.")
                    .foregroundStyle(.secondary)
            case .choosingWindow:
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Choose a Window")
                    .font(.title3.weight(.semibold))
                Text("Pick one of “\(model.displayName)”’s windows to show.")
                    .foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.large)
                    .padding(.bottom, 4)
                Text("Connecting to “\(model.displayName)”…")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if !model.trimmedHost.isEmpty, model.displayName != model.trimmedHost {
                    Text(model.trimmedHost)
                        .foregroundStyle(.secondary)
                }
                if let hint = model.connectHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct NearbyRow: View {
    let host: NearbyHost
    let isChosen: Bool
    let onChoose: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.symbol)
                .font(.system(size: 20))
                .foregroundStyle(isChosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name)
                    .fontWeight(.medium)
                Text(host.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isChosen {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(isChosen ? AnyShapeStyle(.tint.opacity(0.12))
                             : AnyShapeStyle(hovering ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded(onOpen).exclusively(before: TapGesture().onEnded(onChoose)))
        .animation(.smooth(duration: 0.15), value: isChosen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Connect", onOpen)
        .accessibilityAction(.default, onChoose)
    }
}

private struct NoticeView: View {
    let notice: ConnectModel.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.kind == .problem ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.kind == .problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(notice.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .help(notice.detail ?? "")
    }
}

/// A grouped-list section, like System Settings.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}
