import Cocoa

protocol NotchInputBarDelegate: AnyObject {
    func inputBar(_ bar: NotchInputBar, didSubmitText text: String)
    func inputBarDidRequestClose(_ bar: NotchInputBar)
    func inputBarDidClearMessages(_ bar: NotchInputBar)
}

class NotchInputBar: NSView, NSTextFieldDelegate {
    weak var delegate: NotchInputBarDelegate?

    let iconView: NSImageView
    let inputField: NSTextField

    private let defaultIcon = "ellipsis"

    // Command mode
    private var isCommandMode = false
    private var currentCommandIndex = 0
    private var savedInputText = ""

    private struct Command {
        let name: String
        let icon: String
        let action: () -> Void
    }

    private lazy var commands: [Command] = [
        Command(name: "clear", icon: "trash", action: { [weak self] in
            self?.delegate?.inputBarDidClearMessages(self!)
        })
    ]

    override init(frame: NSRect) {
        iconView = NSImageView()
        inputField = NSTextField()

        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10

        setupIcon()
        setupInputField()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupIcon() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: defaultIcon, accessibilityDescription: "Notch")
        iconView.contentTintColor = .systemBlue
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        iconView.alphaValue = 0
        addSubview(iconView)
    }

    private func setupInputField() {
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = "Type to Notch"
        inputField.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.textColor = .white
        inputField.delegate = self
        inputField.alphaValue = 0

        inputField.placeholderAttributedString = NSAttributedString(
            string: "Type to Notch",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .font: NSFont.systemFont(ofSize: 15, weight: .regular)
            ]
        )

        addSubview(inputField)
    }

    func activateConstraints() {
        constraints.forEach { removeConstraint($0) }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            inputField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            inputField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func fadeInContent() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            iconView.animator().alphaValue = 1
            inputField.animator().alphaValue = 1
        }
    }

    func fadeOutContent() {
        iconView.alphaValue = 0
        inputField.alphaValue = 0
    }

    // MARK: - Tool Indicator

    func showToolIndicator(for toolName: String) {
        let iconName: String
        switch toolName {
        case "web_search": iconName = "magnifyingglass"
        case "web_fetch": iconName = "globe"
        case "screenshot": iconName = "display"
        case "camera": iconName = "camera"
        case "memory": iconName = "brain.head.profile"
        case "str_replace_based_edit_tool": iconName = "doc.text"
        case "end_conversation": iconName = "hand.wave"
        case "scheduler": iconName = "clock"
        default: iconName = "gearshape"
        }

        iconView.layer?.removeAllAnimations()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: toolName)
        iconView.contentTintColor = .systemPink

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.5, 1.15, 1.0]
        pop.keyTimes = [0, 0.6, 1.0]
        pop.duration = 0.25
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        iconView.layer?.add(pop, forKey: "popIn")
    }

    func hideToolIndicator() {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.0, 1.15, 0.5]
        pop.keyTimes = [0, 0.4, 1.0]
        pop.duration = 0.2
        pop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self else { return }
            self.iconView.image = NSImage(systemSymbolName: self.defaultIcon, accessibilityDescription: "Notch")
            self.iconView.contentTintColor = .systemBlue

            let popBack = CAKeyframeAnimation(keyPath: "transform.scale")
            popBack.values = [0.5, 1.1, 1.0]
            popBack.keyTimes = [0, 0.6, 1.0]
            popBack.duration = 0.2
            self.iconView.layer?.add(popBack, forKey: "popBack")
        }
        iconView.layer?.add(pop, forKey: "popOut")
        CATransaction.commit()
    }

    // MARK: - Shake

    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-8, 8, -6, 6, -4, 4, -2, 2, 0]
        layer?.add(animation, forKey: "shake")
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertTab(_:)) {
            if isCommandMode {
                cycleToNextCommand()
            } else {
                enterCommandMode()
            }
            return true
        }

        if commandSelector == #selector(insertNewline(_:)) {
            if isCommandMode {
                executeCurrentCommand()
                return true
            }
            let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                inputField.stringValue = ""
                delegate?.inputBar(self, didSubmitText: text)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if isCommandMode {
                exitCommandMode()
                return true
            }
            delegate?.inputBarDidRequestClose(self)
            return true
        }

        return false
    }

    // MARK: - Command Mode

    private func enterCommandMode() {
        guard !commands.isEmpty else { return }
        isCommandMode = true
        currentCommandIndex = 0
        savedInputText = inputField.stringValue
        updateCommandModeUI()
    }

    private func exitCommandMode() {
        isCommandMode = false
        inputField.stringValue = savedInputText
        inputField.isEditable = true
        iconView.contentTintColor = .systemBlue
        iconView.image = NSImage(systemSymbolName: defaultIcon, accessibilityDescription: "Notch")
    }

    private func cycleToNextCommand() {
        currentCommandIndex = (currentCommandIndex + 1) % commands.count
        updateCommandModeUI()
    }

    private func updateCommandModeUI() {
        let cmd = commands[currentCommandIndex]
        iconView.contentTintColor = .systemBlue
        iconView.image = NSImage(systemSymbolName: cmd.icon, accessibilityDescription: cmd.name)
        inputField.isEditable = false
        inputField.stringValue = cmd.name
    }

    private func executeCurrentCommand() {
        let cmd = commands[currentCommandIndex]
        exitCommandMode()
        inputField.stringValue = ""
        cmd.action()
    }
}
