import GlassActCore
import GlassActSession
import GlassActTransport
import SwiftUI

/// Pick a Mac and connect. Nearby Macs (Bonjour) come first as large
/// targets; recents and a typed address follow. While a connection is on its
/// way, a card over the screen says what's happening: connecting, the code
/// the Mac shows while its user decides, or a sign-in form.
struct ConnectScreen: View {
    @Bindable var model: SessionModel
    @State private var showingSettings = false
    @State private var showingAddress = false
    @FocusState private var addressFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header
                    if let notice = model.notice { NoticeBanner(notice: notice, model: model) }
                    nearbySection
                    if !model.recents.isEmpty { recentSection }
                    addressSection
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Backdrop())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsSheet(model: model) }
        }
        .overlay {
            if model.phase.isBusy {
                ProgressCard(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.phase)
        .animation(.smooth(duration: 0.3), value: model.notice)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glass Act")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Use a Mac from this iPad.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Nearby

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Nearby")
            if model.nearby.isBlocked {
                ContentUnavailableView {
                    Label("Local Network Is Off", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("To find Macs nearby, allow Glass Act to use the local network in Settings.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
            } else if model.nearby.hosts.isEmpty {
                HStack(spacing: 14) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looking for Macs…").font(.headline)
                        Text("Open Glass Act Host on a Mac on this network, or type its address below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                GlassEffectContainer(spacing: 16) {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.nearby.hosts) { host in
                            MacCard(host: host) { model.choose(host) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Recent")
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(model.recents, id: \.self) { address in
                            Button { model.choose(recent: address) } label: {
                                Label(address, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.glass)
                            .contextMenu {
                                Button("Remove from Recents", systemImage: "trash", role: .destructive) {
                                    withAnimation { model.forgetRecent(address) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Address

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Connect to an Address")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Mac name or address", text: $model.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { model.connect() }
                    Button("Connect") { model.connect() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.trimmedHost.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                DisclosureGroup("Port and host key", isExpanded: $showingAddress) {
                    VStack(spacing: 12) {
                        LabeledContent("Port") {
                            TextField("4433", text: $model.port)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                        LabeledContent("Host key") {
                            TextField("Optional: ga1…", text: $model.hostKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospaced())
                        }
                        Text("Leave the key empty to trust the Mac the first time you connect; Glass Act remembers it and warns you if it ever changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A nearby Mac: a large target with its kind of computer.
private struct MacCard: View {
    let host: NearbyHost
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: host.symbol)
                    .font(.system(size: 40, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(host.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .hoverEffect(.lift)
        .accessibilityLabel("Connect to \(host.name)")
        .accessibilityHint(host.isLaptop ? "MacBook" : "Mac")
    }
}

/// A soft wash behind the glass, in the app's green.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [Color.green.opacity(0.16), Color.teal.opacity(0.08), .clear],
                           startPoint: .topLeading, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}

/// What went wrong last, with the way forward.
private struct NoticeBanner: View {
    let notice: SessionModel.Notice
    let model: SessionModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: notice.kind == .problem ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.title2)
                .foregroundStyle(notice.kind == .problem ? .orange : .accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.headline)
                Text(notice.text).font(.subheadline).foregroundStyle(.secondary)
                if notice.offersForgetKey {
                    Button("Forget Saved Key", role: .destructive) { model.forgetSavedKey() }
                        .buttonStyle(.glass)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { model.notice = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }
}

/// Over the connect screen while a connection is on its way.
private struct ProgressCard: View {
    @Bindable var model: SessionModel
    @FocusState private var passwordFocused: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.25)).ignoresSafeArea()
            VStack(spacing: 22) {
                content
            }
            .padding(32)
            .frame(maxWidth: 440)
            .glassEffect(.regular, in: .rect(cornerRadius: 36))
            .padding(24)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case let .awaitingApproval(code):
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text("Waiting for “\(model.sessionName)”").font(.title2.bold()).multilineTextAlignment(.center)
            Text("On the Mac, click Allow. Check that it shows this code:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .tracking(6)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            cancelButton
        case .signingIn:
            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Sign in to “\(model.sessionName)”").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Use the name and password of the account on that Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                TextField("Name", text: $model.signInUser)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { passwordFocused = true }
                SecureField("Password", text: $model.signInPassword)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($passwordFocused)
                    .onSubmit { model.signIn() }
            }
            .textFieldStyle(.roundedBorder)
            if let error = model.signInError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                cancelButton
                Button {
                    model.signIn()
                } label: {
                    if model.signInBusy { ProgressView() } else { Text("Sign In") }
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.canSignIn)
                .keyboardShortcut(.defaultAction)
            }
        case let .reconnecting(attempt):
            ProgressView().controlSize(.large)
            Text("Reconnecting to “\(model.sessionName)”…").font(.title3.bold()).multilineTextAlignment(.center)
            Text("Attempt \(attempt)").foregroundStyle(.secondary).monospacedDigit()
            cancelButton
        case .loadingPicture:
            ProgressView().controlSize(.large)
            Text("Loading “\(model.sessionName)”’s screen…").font(.title3.bold()).multilineTextAlignment(.center)
            Text("Connected. The picture is on its way.").foregroundStyle(.secondary)
            cancelButton
        default:
            ProgressView().controlSize(.large)
            Text("Connecting to “\(model.sessionName)”…").font(.title3.bold()).multilineTextAlignment(.center)
            if let hint = model.connectHint {
                Text(hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { model.cancel() }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
    }
}

/// What applies to every connection.
struct SettingsSheet: View {
    @Bindable var model: SessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $model.resolution) {
                        ForEach(SessionModel.Resolution.allCases) { r in
                            Label(r.title, systemImage: r.symbol).tag(r)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Resolution")
                } footer: {
                    Text(model.resolution.explanation)
                }
                Section {
                    Picker("Picture", selection: $model.motion) {
                        ForEach(SessionModel.MotionPreference.allCases) { m in Text(m.title).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Use AV1 Video", isOn: $model.av1)
                        .disabled(!VTRegionDecoder.canDecodeAV1)
                } header: {
                    Text("On a Slow Network")
                } footer: {
                    Text("Balanced keeps text crisp at fewer frames per second. Sharp Text also keeps moving content sharper when the network has room. Smooth Motion lets moving content soften so more frames get through. "
                         + (VTRegionDecoder.canDecodeAV1
                            ? "AV1 keeps moving text sharper than HEVC but uses more bandwidth, and needs a Mac with Apple silicon."
                            : "AV1 needs an iPad with an M3 chip or later."))
                }
                Section {
                    LabeledContent("This iPad’s key") {
                        Text(QUICIdentity.abbreviatedKeyString(model.viewerFingerprint))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Macs you allow remember this key. It stays on this iPad.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.versionDescription)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension Bundle {
    /// "26.10.6 (202610300638, 1516547)", as the Mac apps' About panel.
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let commit = (infoDictionary?["GlassActCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return "\(version) (\(build)\(commit.map { ", \($0)" } ?? ""))"
    }
}
