import Cocoa

class InputBarWindow: NSPanel {
    private let inputBar: NotchInputBar
    private let chatHistory: ChatHistoryView
    private var cameraPreview: CameraPreviewView?
    private weak var appDelegate: AppDelegate?

    // Dimensions
    let finalWidth: CGFloat = 380
    let finalHeight: CGFloat = 44
    private let notchWidth: CGFloat = 180
    private let notchHeight: CGFloat = 32
    private let maxChatHeight: CGFloat
    private let cameraPreviewHeight: CGFloat = 285

    var hasExpandedForChat = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        self.maxChatHeight = screenFrame.height / 2

        inputBar = NotchInputBar(frame: NSRect(x: 0, y: 0, width: 180, height: 32))
        chatHistory = ChatHistoryView(contentWidth: 380)

        let startX = (screenFrame.width - notchWidth) / 2
        let startY = screenFrame.height - notchHeight - 5

        super.init(
            contentRect: NSRect(x: startX, y: startY, width: notchWidth, height: notchHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false

        inputBar.delegate = self
        inputBar.autoresizingMask = [.width, .height]
        contentView = inputBar

        animateIn()
    }

    // MARK: - Public API (called from AppDelegate)

    func showToolIndicator(for toolName: String) {
        inputBar.showToolIndicator(for: toolName)
    }

    func hideToolIndicator() {
        inputBar.hideToolIndicator()
    }

    func shakeInputBar() {
        inputBar.shake()
    }

    func showEphemeralError(_ message: String) {
        chatHistory.showEphemeralError(message, relativeTo: inputBar)
    }

    func reloadMessages() {
        guard let screen = NSScreen.main else { return }
        let messages = appDelegate?.messages ?? []

        if messages.isEmpty {
            if hasExpandedForChat { collapseChat() }
            return
        }

        if !hasExpandedForChat {
            expandForChat()
            return
        }

        // Already expanded — update in place
        let chatHeight = chatHistory.calculateHeight(for: messages, maxHeight: maxChatHeight)
        let totalHeight = finalHeight + chatHeight

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        setFrame(NSRect(x: finalX, y: finalY - chatHeight, width: finalWidth, height: totalHeight), display: true)

        inputBar.frame = NSRect(x: 0, y: totalHeight - finalHeight, width: finalWidth, height: finalHeight)
        chatHistory.scrollView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: chatHeight)

        chatHistory.setupBubbles(for: messages)
        chatHistory.scrollView.alphaValue = 1
        chatHistory.fadeInNewestBubble()

        makeFirstResponder(inputBar.inputField)
    }

    func showTypingIndicator() {
        guard let screen = NSScreen.main else { return }
        let messages = appDelegate?.messages ?? []

        // Insert the typing row (returns its height, or 0 if already showing)
        let typingHeight = chatHistory.showTypingIndicator()
        guard typingHeight > 0 else { return }  // already visible

        if !hasExpandedForChat {
            let chatHeight = typingHeight + 8
            let totalHeight = finalHeight + chatHeight

            let finalX = (screen.frame.width - finalWidth) / 2
            let finalY = screen.frame.height - finalHeight - 52

            transitionToContentLayout(contentView: chatHistory.scrollView, contentHeight: chatHeight, totalHeight: totalHeight)
            setFrame(NSRect(x: finalX, y: finalY - chatHeight, width: finalWidth, height: totalHeight), display: true)
            hasExpandedForChat = true

            if let documentView = chatHistory.scrollView.documentView {
                documentView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: chatHeight)
                chatHistory.stackView.removeFromSuperview()
                documentView.addSubview(chatHistory.stackView)
                NSLayoutConstraint.activate([
                    chatHistory.stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
                    chatHistory.stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
                    chatHistory.stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
                ])
            }
        }

        // Resize to fit messages + typing indicator
        let messagesHeight = chatHistory.calculateHeight(for: messages, maxHeight: maxChatHeight)
        let chatHeight = messagesHeight + typingHeight + (messages.isEmpty ? 8 : 0)
        let totalHeight = finalHeight + chatHeight

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        setFrame(NSRect(x: finalX, y: finalY - chatHeight, width: finalWidth, height: totalHeight), display: true)
        inputBar.frame = NSRect(x: 0, y: totalHeight - finalHeight, width: finalWidth, height: finalHeight)
        chatHistory.scrollView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: chatHeight)
        chatHistory.scrollView.alphaValue = 1

        if let documentView = chatHistory.scrollView.documentView {
            documentView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: chatHeight)
        }

        contentView?.layoutSubtreeIfNeeded()
        makeFirstResponder(inputBar.inputField)
    }

    func hideTypingIndicator() {
        chatHistory.hideTypingIndicator()
    }

    func showCameraCapture(completion: @escaping (ToolResult) -> Void) {
        guard let screen = NSScreen.main else {
            completion(.error("No screen available"))
            return
        }

        let cameraGap: CGFloat = 8
        let camView = CameraPreviewView(frame: NSRect(x: 0, y: 0, width: finalWidth, height: cameraPreviewHeight))
        camView.targetHeight = cameraPreviewHeight
        self.cameraPreview = camView

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52
        let totalHeight = finalHeight + cameraGap + cameraPreviewHeight

        if hasExpandedForChat {
            chatHistory.scrollView.alphaValue = 0
        }

        // Start with camera view at 0 height (visor closed)
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight))
        wrapper.wantsLayer = true
        wrapper.autoresizingMask = [.width, .height]

        inputBar.removeFromSuperview()
        // Pin input bar to top during window resize (.minYMargin = flexible space below)
        inputBar.autoresizingMask = [.width, .minYMargin]
        inputBar.frame = NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight)

        camView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: 0)

        wrapper.addSubview(inputBar)
        wrapper.addSubview(camView)
        contentView = wrapper

        setFrame(NSRect(x: finalX, y: finalY, width: finalWidth, height: finalHeight), display: true)

        // When camera session is ready, animate the visor open
        camView.onReadyForReveal = { [weak self] in
            guard let self = self else { return }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)

                // Grow window downward — inputBar stays at top via .minYMargin
                self.animator().setFrame(
                    NSRect(x: finalX, y: finalY - cameraGap - self.cameraPreviewHeight,
                           width: self.finalWidth, height: totalHeight),
                    display: true
                )
            }, completionHandler: { [weak self, weak camView] in
                guard let self = self, let camView = camView else { return }

                // Finalize layout after animation
                self.inputBar.frame = NSRect(x: 0, y: totalHeight - self.finalHeight,
                                             width: self.finalWidth, height: self.finalHeight)
                camView.frame = NSRect(x: 0, y: 0, width: self.finalWidth, height: self.cameraPreviewHeight)
                camView.beginCountdown()
            })
        }

        camView.startCapture { [weak self] result in
            guard let self = self else { return }
            self.cameraPreview = nil

            // Restore layout
            let messages = self.appDelegate?.messages ?? []
            if !messages.isEmpty {
                self.expandForChat()
            } else {
                self.collapseToInputOnly()
            }

            completion(result)
        }
    }

    // MARK: - Layout Transitions

    func expandForChat() {
        guard let screen = NSScreen.main else { return }

        let messages = appDelegate?.messages ?? []
        let chatHeight = chatHistory.calculateHeight(for: messages, maxHeight: maxChatHeight)
        let totalHeight = finalHeight + chatHeight

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        transitionToContentLayout(contentView: chatHistory.scrollView, contentHeight: chatHeight, totalHeight: totalHeight)
        chatHistory.setupBubbles(for: messages)

        setFrame(NSRect(x: finalX, y: finalY - chatHeight, width: finalWidth, height: totalHeight), display: true)

        hasExpandedForChat = true
        chatHistory.animateBubblesIn()
        makeFirstResponder(inputBar.inputField)
    }

    private func transitionToContentLayout(contentView bottomView: NSView, contentHeight: CGFloat, totalHeight: CGFloat) {
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: finalWidth, height: totalHeight))
        wrapper.wantsLayer = true
        wrapper.autoresizingMask = [.width, .height]

        inputBar.removeFromSuperview()
        inputBar.autoresizingMask = []
        inputBar.frame = NSRect(x: 0, y: totalHeight - finalHeight, width: finalWidth, height: finalHeight)
        bottomView.frame = NSRect(x: 0, y: 0, width: finalWidth, height: contentHeight)

        wrapper.addSubview(inputBar)
        wrapper.addSubview(bottomView)
        contentView = wrapper
    }

    private func collapseChat() {
        guard let screen = NSScreen.main else { return }

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        chatHistory.collapse()

        inputBar.removeFromSuperview()
        inputBar.frame = NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        inputBar.autoresizingMask = [.width, .height]

        setFrame(NSRect(x: finalX, y: finalY, width: finalWidth, height: finalHeight), display: true)
        contentView = inputBar
        hasExpandedForChat = false

        inputBar.iconView.alphaValue = 1
        inputBar.inputField.alphaValue = 1
        makeFirstResponder(inputBar.inputField)
    }

    private func collapseToInputOnly() {
        guard let screen = NSScreen.main else { return }

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        inputBar.removeFromSuperview()
        inputBar.autoresizingMask = [.width, .height]
        inputBar.frame = NSRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        contentView = inputBar

        hasExpandedForChat = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            self.animator().setFrame(
                NSRect(x: finalX, y: finalY, width: finalWidth, height: finalHeight),
                display: true
            )
        })

        makeFirstResponder(inputBar.inputField)
    }

    // MARK: - Animate In / Close

    private func animateIn() {
        guard let screen = NSScreen.main else { return }

        let finalX = (screen.frame.width - finalWidth) / 2
        let finalY = screen.frame.height - finalHeight - 52

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            self.animator().setFrame(
                NSRect(x: finalX, y: finalY, width: finalWidth, height: finalHeight),
                display: true
            )
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.inputBar.layer?.cornerRadius = 12
            self.inputBar.activateConstraints()
            self.inputBar.fadeInContent()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.makeFirstResponder(self.inputBar.inputField)

                let messages = self.appDelegate?.messages ?? []
                if !messages.isEmpty {
                    self.expandForChat()
                }
            }
        })
    }

    private func performClose() {
        super.close()
    }

    override func close() {
        guard let screen = NSScreen.main else {
            performClose()
            return
        }

        let notchX = (screen.frame.width - notchWidth) / 2
        let notchY = screen.frame.height - notchHeight - 5

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.inputBar.iconView.animator().alphaValue = 0
            self.inputBar.inputField.animator().alphaValue = 0
            self.chatHistory.scrollView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                self.animator().setFrame(
                    NSRect(x: notchX, y: notchY, width: self.notchWidth, height: self.notchHeight),
                    display: true
                )
            }, completionHandler: {
                self.performClose()
            })
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "a", "c", "v", "x", "z":
                return super.performKeyEquivalent(with: event)
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NotchInputBarDelegate

extension InputBarWindow: NotchInputBarDelegate {
    func inputBar(_ bar: NotchInputBar, didSubmitText text: String) {
        guard appDelegate?.addMessage(text, isFromUser: true) == true else { return }
        reloadMessages()
        chatHistory.scrollView.documentView?.scroll(.zero)
    }

    func inputBarDidRequestClose(_ bar: NotchInputBar) {
        close()
    }

    func inputBarDidClearMessages(_ bar: NotchInputBar) {
        appDelegate?.clearMessages()
    }
}

// Flipped view so content grows from top to bottom
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
