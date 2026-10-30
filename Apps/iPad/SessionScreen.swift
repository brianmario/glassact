import GlassActCore
import GlassActSession
import SwiftUI
import UIKit

/// The Mac's screen, edge to edge, with a few controls in a glass capsule
/// that tucks itself away. The picture is the point: the controls stay
/// small, out of the menu bar's way, and fade after a few seconds.
struct SessionScreen: View {
    @Bindable var model: SessionModel
    let controller: ViewerController
    let grid: TileGrid
    @State private var canvas = CanvasHandle()
    @State private var controlsShown = true
    @State private var hideWork: DispatchWorkItem?
    @State private var showingInfo = false
    @Namespace private var glass

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            CanvasRepresentable(model: model, controller: controller, grid: grid,
                                generation: model.gridGeneration, handle: canvas)
                .ignoresSafeArea()
                .accessibilityLabel("Screen of \(model.sessionName)")
            if let notice = model.hostNotice {
                Label(notice, systemImage: "person.2.slash")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: 420)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
            }
            controls
                .padding(.top, 10)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .animation(.smooth(duration: 0.35), value: controlsShown)
        .animation(.smooth, value: model.hostNotice)
        .onAppear { scheduleHide() }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            if controlsShown {
                HStack(spacing: 6) {
                    Button("Keyboard", systemImage: "keyboard") {
                        canvas.view?.keyboard.becomeFirstResponder()
                        scheduleHide()
                    }
                    .keyboardShortcut("k", modifiers: [.command, .control])
                    PasteToMac { text in model.sendClipboard(text) }
                        .frame(width: 44, height: 44)
                        .help("Paste to Mac: copies this iPad’s clipboard to the Mac, ready for ⌘V")
                    Button("Actual Size", systemImage: "arrow.down.right.and.arrow.up.left") {
                        canvas.view?.resetZoom()
                        scheduleHide()
                    }
                    Button("Connection", systemImage: "antenna.radiowaves.left.and.right") {
                        showingInfo.toggle()
                        scheduleHide()
                    }
                    .popover(isPresented: $showingInfo) { info }
                    Divider().frame(height: 24)
                    Button("Disconnect", systemImage: "xmark", role: .destructive) { model.disconnect() }
                        .keyboardShortcut("w", modifiers: [.command, .control])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.title3)
                // A bar, like the system's: it stops growing at the largest
                // text sizes, and a long press shows each button enlarged.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityShowsLargeContentViewer()
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("controls", in: glass)
                .controlSize(.large)
                .contentShape(.capsule)
                .simultaneousGesture(TapGesture().onEnded { scheduleHide() })
            } else {
                Button {
                    controlsShown = true
                    scheduleHide()
                } label: {
                    Capsule().fill(.white.opacity(0.7)).frame(width: 44, height: 5)
                        .frame(width: 88, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("controls", in: glass)
                .accessibilityLabel("Show Controls")
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.sessionName, systemImage: "desktopcomputer").font(.headline)
            if let line = model.throughput {
                Text(line).monospacedDigit()
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
            Text("\(grid.width) × \(grid.height) pixels · \(model.resolution.title)")
                .foregroundStyle(.secondary)
            if let code = model.verificationCode {
                Text("Code \(code)").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(18)
        .frame(minWidth: 260, alignment: .leading)
    }

    /// `--keep-controls`: leave them up (screenshots, demos, UI tests).
    private static let keepControls = CommandLine.arguments.contains("--keep-controls")

    private func scheduleHide() {
        hideWork?.cancel()
        guard !Self.keepControls else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { if !showingInfo { controlsShown = false } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// The canvas view, for SwiftUI buttons that act on it.
@MainActor final class CanvasHandle {
    weak var view: CanvasView?
}

struct CanvasRepresentable: UIViewRepresentable {
    let model: SessionModel
    let controller: ViewerController
    let grid: TileGrid
    let generation: Int
    let handle: CanvasHandle

    final class Coordinator {
        var generation = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(controller: controller, grid: grid)
        view.onSizeSettled = { [weak model] size in model?.viewportSettled(size) }
        context.coordinator.generation = generation
        handle.view = view
        view.startPresenting()
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        guard context.coordinator.generation != generation else { return }
        context.coordinator.generation = generation
        view.reconfigure(grid: grid)
    }

    static func dismantleUIView(_ view: CanvasView, coordinator: Coordinator) {
        view.releaseHeldKeys()
        view.stopPresenting()
    }
}

/// Paste to Mac: this iPad's clipboard text, sent to the Mac's clipboard
/// for ⌘V there. A system paste control, so reading the clipboard needs
/// no permission prompt (the person's tap is the permission), drawn to
/// match the glass bar around it.
struct PasteToMac: UIViewRepresentable {
    let send: (String) -> Void

    final class Target: UIView {
        var send: (String) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.send(text)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                }
            }
        }
    }

    func makeUIView(context: Context) -> Target {
        let target = Target()
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconOnly
        config.cornerStyle = .capsule
        // The system keeps a paste control opaque: the app's green, the one
        // accent in the bar.
        config.baseBackgroundColor = .systemGreen
        config.baseForegroundColor = .white
        let control = UIPasteControl(configuration: config)
        control.target = target
        control.translatesAutoresizingMaskIntoConstraints = false
        target.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: target.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: target.centerYAnchor),
            control.widthAnchor.constraint(equalTo: target.widthAnchor),
            control.heightAnchor.constraint(equalTo: target.heightAnchor),
        ])
        target.send = send
        return target
    }

    func updateUIView(_ target: Target, context: Context) { target.send = send }
}
