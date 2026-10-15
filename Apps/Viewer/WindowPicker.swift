import AppKit
import GlassActWire
import SwiftUI

/// Single-window mode — the picker: a grid of the host's shareable
/// windows (thumbnail + app + title), à la FaceTime/Zoom window sharing. Pick
/// one → `onPick(windowID)`; close or Cancel → `onCancel`. Thumbnails are
/// small WebP/AVIF stills the host sent inline; NSImage decodes both natively.
@MainActor final class WindowPicker: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onPick: ((UInt32) -> Void)?
    private var onCancel: (() -> Void)?
    private var didChoose = false

    func show(windows: [WireWindow], hostName: String,
              onPick: @escaping (UInt32) -> Void,
              onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
        self.didChoose = false

        let items = windows.map(PickerItem.init)
        let view = WindowPickerView(items: items, hostName: hostName,
                                    onPick: { [weak self] id in self?.pick(id) },
                                    onCancel: { [weak self] in self?.cancel() })
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Choose a Window"
        // ARC owns this window; without this, the red-X close path has AppKit
        // release it too (isReleasedWhenClosed defaults true outside window
        // controllers) — an over-release crash on cancel.
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 760, height: 560))
        w.contentMinSize = NSSize(width: 520, height: 380)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    private func pick(_ id: UInt32) {
        didChoose = true
        close()
        onPick?(id)
    }

    private func cancel() {
        guard !didChoose else { return }
        didChoose = true
        close()
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !didChoose { didChoose = true; onCancel?() }
        window = nil
        return true
    }
}

private struct PickerItem: Identifiable {
    let id: UInt32
    let app: String
    let title: String
    let image: NSImage?

    init(_ w: WireWindow) {
        id = w.windowID
        app = w.appName.isEmpty ? "Window" : w.appName
        title = w.title
        image = w.thumb.isEmpty ? nil : NSImage(data: Data(w.thumb))
    }
}

private struct WindowPickerView: View {
    let items: [PickerItem]
    let hostName: String
    let onPick: (UInt32) -> Void
    let onCancel: () -> Void
    @State private var selection: UInt32?
    @State private var query = ""

    private var filtered: [PickerItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.app.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a Window")
                        .font(.title2.weight(.semibold))
                    Text("It opens on this Mac as its own window, and you can use it here.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 16)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(items.isEmpty ? "No Windows to Share" : "No Matches",
                                       systemImage: "macwindow",
                                       description: Text(items.isEmpty
                                           ? "“\(hostName)” has no windows that can be shared right now."
                                           : "No window’s app or title contains “\(query)”."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 18)],
                              spacing: 20) {
                        ForEach(filtered) { item in
                            WindowCard(item: item, isSelected: selection == item.id)
                                .onTapGesture(count: 2) { onPick(item.id) }
                                .onTapGesture { selection = item.id }
                                .accessibilityAddTraits(selection == item.id ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { selection = item.id }
                                .accessibilityAction(named: "Show") { onPick(item.id) }
                        }
                    }
                    .padding(24)
                }
            }

            Divider()

            HStack {
                Text(items.count == 1 ? "1 window" : "\(items.count) windows")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("Show Window") { if let selection { onPick(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selection == nil)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .onAppear { if items.count == 1 { selection = items[0].id } }
    }
}

private struct WindowCard: View {
    let item: PickerItem
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.6))
                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .padding(12)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
            )
            .scaleEffect(hovering && !isSelected ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.app)
                    .font(.headline)
                    .lineLimit(1)
                if !item.title.isEmpty {
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
        .help(item.title.isEmpty ? item.app : "\(item.app) — \(item.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title.isEmpty ? item.app : "\(item.app), \(item.title)")
    }
}
