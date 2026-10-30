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
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        model.sendClipboard(text)
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .tint(.primary)
                    .accessibilityLabel("Paste to Mac")
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

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { if !showingInfo { controlsShown = false } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
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
