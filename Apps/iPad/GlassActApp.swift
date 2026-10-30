import GlassActSession
import SwiftUI

/// Glass Act for iPad: a Viewer. The engine, transport and session are the
/// package's, shared with the Mac Viewer; this app is the screens and the
/// touch, pointer and keyboard input around them.
@main
struct GlassActApp: App {
    @State private var model = SessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .tint(.green)
        }
        .onChange(of: scenePhase) { old, new in
            switch new {
            case .background: model.didEnterBackground()
            case .active where old == .background || old == .inactive: model.willEnterForeground()
            default: break
            }
        }
        .commands {
            CommandMenu("Session") {
                Button("Disconnect") { model.disconnect() }
                    .disabled(model.controller == nil)
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: SessionModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if model.phase == .inSession, let controller = model.controller, let grid = model.grid {
                SessionScreen(model: model, controller: controller, grid: grid)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                // Keeps the keyboard's safe area, so its cards and fields
                // move out of the keyboard's way.
                ConnectScreen(model: model)
                    .transition(.opacity)
            }
        }
        .background {
            // The whole window, keyboard or not.
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        noteViewport(proxy.size)
                        model.applyLaunchArguments(CommandLine.arguments)
                    }
                    .onChange(of: proxy.size) { _, size in noteViewport(size) }
            }
            .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.4), value: model.phase == .inSession)
    }

    /// The whole window is the picture's: the size the Mac is asked for.
    private func noteViewport(_ size: CGSize) {
        guard size.width > 0, model.phase != .inSession else { return }
        model.noteScreen(size: size, scale: displayScale)
    }
}
