import GlassActSession
import UIKit

/// The on-screen keyboard's end of a session: a hidden view that takes text
/// while the keyboard is up. The host takes keys, not text (TEXT_INPUT is
/// for agents, §14), so each character goes as the US-layout keystroke that
/// types it (`KeyMap.keystroke`), shift included. A bar above the keyboard
/// has what it lacks: escape, tab, the arrows, and ⌃ ⌥ ⌘ that latch for the
/// next key.
///
/// Hardware keys pressed while it's first responder go to the canvas's
/// handler (`onPresses`), so they reach the host as physical keys.
final class KeyboardProxy: UIView, UIKeyInput {
    /// A key to send: (key code, down, flags).
    var onKey: ((UInt16, Bool, UInt32) -> Void)?
    /// Hardware presses: (presses, down) → whether they were handled.
    var onPresses: ((Set<UIPress>, Bool) -> Bool)?

    private lazy var bar = KeyBar { [weak self] action in self?.perform(action) }
    private var latched: KeyMap.Modifier = []

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isHidden = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    // MARK: UIKeyInput

    var hasText: Bool { true } // delete always reaches the host

    func insertText(_ text: String) {
        for ch in text {
            guard let stroke = KeyMap.keystroke(for: ch) else { continue }
            var mods = latched
            if stroke.shift { mods.insert(.shift) }
            tap(stroke.code, modifiers: mods)
        }
        unlatch()
    }

    func deleteBackward() {
        tap(0x33, modifiers: latched) // delete
        unlatch()
    }

    // MARK: Hardware presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, true) != true { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) != true { super.pressesCancelled(presses, with: event) }
    }

    // MARK: Keys

    /// Modifiers down, the key down and up, modifiers up: what a person's
    /// fingers would do.
    private func tap(_ code: UInt16, modifiers: KeyMap.Modifier, extraFlags: UInt32 = 0) {
        let held = KeyMap.Modifier.order.filter { modifiers.contains($0) }
        var flags: UInt32 = 0
        for m in held {
            flags |= m.eventFlags
            if let c = m.keyCode { onKey?(c, true, flags) }
        }
        onKey?(code, true, flags | extraFlags)
        onKey?(code, false, flags | extraFlags)
        for m in held.reversed() {
            flags &= ~m.eventFlags
            if let c = m.keyCode { onKey?(c, false, flags) }
        }
    }

    private func perform(_ action: KeyBar.Action) {
        switch action {
        case let .key(code, flags):
            tap(code, modifiers: latched, extraFlags: flags)
            unlatch()
        case let .latch(modifier):
            if latched.contains(modifier) { latched.remove(modifier) } else { latched.insert(modifier) }
            bar.show(latched: latched)
        case .dismiss:
            resignFirstResponder()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    }

    private func unlatch() {
        guard !latched.isEmpty else { return }
        latched = []
        bar.show(latched: latched)
    }

    func releaseHeldKeys() { unlatch() }
}

/// The bar above the on-screen keyboard: the keys a Mac needs that an iPad
/// keyboard doesn't have.
final class KeyBar: UIInputView {
    enum Action {
        case key(UInt16, flags: UInt32)
        case latch(KeyMap.Modifier)
        case dismiss
    }

    static let height: CGFloat = 52
    private let act: (Action) -> Void
    private var modifierButtons: [(KeyMap.Modifier, UIButton)] = []
    private static let fn: UInt32 = 1 << 23, numericPad: UInt32 = 1 << 21

    init(act: @escaping (Action) -> Void) {
        self.act = act
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            stack.heightAnchor.constraint(equalToConstant: 38),
        ])
        stack.addArrangedSubview(key("esc", label: "Escape", .key(0x35, flags: 0)))
        stack.addArrangedSubview(key("tab", label: "Tab", .key(0x30, flags: 0)))
        for (modifier, title, name) in [(KeyMap.Modifier.control, "⌃", "Control"),
                                        (.option, "⌥", "Option"), (.command, "⌘", "Command")] {
            let button = key(title, label: name, .latch(modifier))
            modifierButtons.append((modifier, button))
            stack.addArrangedSubview(button)
        }
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        for (symbol, name, code) in [("arrow.left", "Left Arrow", UInt16(0x7B)), ("arrow.down", "Down Arrow", 0x7D),
                                     ("arrow.up", "Up Arrow", 0x7E), ("arrow.right", "Right Arrow", 0x7C)] {
            stack.addArrangedSubview(key(symbol: symbol, label: name, .key(code, flags: Self.fn | Self.numericPad)))
        }
        stack.addArrangedSubview(key(symbol: "keyboard.chevron.compact.down", label: "Hide Keyboard", .dismiss))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func key(_ title: String? = nil, symbol: String? = nil, label: String, _ action: Action) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol) }
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = UIFont.preferredFont(forTextStyle: .callout).withWeight(.medium)
            return attrs
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        let button = UIButton(configuration: config, primaryAction: UIAction { [act] _ in act(action) })
        button.accessibilityLabel = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Latched modifiers look pressed until the next key.
    func show(latched: KeyMap.Modifier) {
        for (modifier, button) in modifierButtons {
            var config = latched.contains(modifier) ? UIButton.Configuration.prominentGlass()
                                                    : UIButton.Configuration.glass()
            config.title = button.configuration?.title
            config.titleTextAttributesTransformer = button.configuration?.titleTextAttributesTransformer
            config.contentInsets = button.configuration?.contentInsets ?? .zero
            button.configuration = config
            button.accessibilityTraits = latched.contains(modifier) ? [.button, .selected] : .button
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
