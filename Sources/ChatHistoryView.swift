import Cocoa

class ChatHistoryView: NSView {
    let scrollView: NSScrollView
    let stackView: NSStackView

    private let bubbleSpacing: CGFloat = 8
    private let typingBubbleHeight: CGFloat = 32
    private var typingIndicator: NSView?
    private var typingDots: [NSView] = []
    private var typingAnimationTimer: Timer?

    var contentWidth: CGFloat

    override init(frame: NSRect) {
        contentWidth = frame.width
        scrollView = NSScrollView()
        stackView = NSStackView()

        super.init(frame: frame)
        setupScrollView()
    }

    required init?(coder: NSCoder) { fatalError() }

    convenience init(contentWidth: CGFloat) {
        self.init(frame: .zero)
        self.contentWidth = contentWidth
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.scrollerStyle = .overlay
        scrollView.alphaValue = 0

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .trailing
        stackView.spacing = bubbleSpacing
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let flippedView = FlippedView()
        flippedView.addSubview(stackView)
        scrollView.documentView = flippedView
    }

    // MARK: - Height Calculation

    func calculateHeight(for messages: [ChatMessage], maxHeight: CGFloat) -> CGFloat {
        guard !messages.isEmpty else { return 0 }

        var totalHeight: CGFloat = 16
        for message in messages {
            let label = NSTextField(wrappingLabelWithString: message.text)
            label.font = NSFont.systemFont(ofSize: 14, weight: .regular)
            label.preferredMaxLayoutWidth = contentWidth - 80
            let textHeight = label.intrinsicContentSize.height
            totalHeight += textHeight + 20 + bubbleSpacing
        }

        return min(totalHeight, maxHeight)
    }

    // MARK: - Bubble Management

    func setupBubbles(for messages: [ChatMessage]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !messages.isEmpty else { return }

        let maxHeight = NSScreen.main?.frame.height ?? 1080
        let chatHeight = calculateHeight(for: messages, maxHeight: maxHeight / 2)

        if let documentView = scrollView.documentView {
            documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: chatHeight)
            stackView.removeFromSuperview()
            documentView.addSubview(stackView)

            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
                stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            ])
        }

        for message in messages {
            let row = createBubbleRow(for: message)
            row.alphaValue = 0
            stackView.addArrangedSubview(row)
        }
    }

    func animateBubblesIn() {
        scrollView.alphaValue = 1

        for (index, bubble) in stackView.arrangedSubviews.enumerated() {
            let delay = Double(index) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                    bubble.animator().alphaValue = 1
                }
            }
        }
    }

    func fadeInNewestBubble() {
        scrollView.alphaValue = 1

        if let first = stackView.arrangedSubviews.first, first.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                first.animator().alphaValue = 1
            }
        }

        for bubble in stackView.arrangedSubviews.dropFirst() {
            bubble.alphaValue = 1
        }
    }

    func collapse() {
        scrollView.alphaValue = 0
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scrollView.removeFromSuperview()
    }

    // MARK: - Bubble Creation

    private func createBubbleRow(for message: ChatMessage) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.translatesAutoresizingMaskIntoConstraints = false

        if message.isFromUser {
            bubble.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        } else {
            bubble.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.9).cgColor
        }
        bubble.layer?.cornerRadius = 12

        let label = NSTextField(wrappingLabelWithString: message.text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = .white
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = contentWidth - 80

        bubble.addSubview(label)
        row.addSubview(bubble)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),

            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth - 48),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            row.widthAnchor.constraint(equalToConstant: contentWidth - 32),
        ])

        if message.isFromUser {
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        }

        return row
    }

    // MARK: - Typing Indicator

    func showTypingIndicator() -> CGFloat {
        guard typingIndicator == nil else { return 0 }

        let typingRow = createTypingRow()
        typingRow.alphaValue = 0
        typingIndicator = typingRow

        stackView.insertArrangedSubview(typingRow, at: 0)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            typingRow.animator().alphaValue = 1
        }

        // Dot animation
        var dotIndex = 0
        typingAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self, !self.typingDots.isEmpty else { return }
            for (i, dot) in self.typingDots.enumerated() {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    dot.animator().alphaValue = (i == dotIndex % 3) ? 1.0 : 0.4
                }
            }
            dotIndex += 1
        }

        return typingBubbleHeight + bubbleSpacing
    }

    func hideTypingIndicator() {
        typingAnimationTimer?.invalidate()
        typingAnimationTimer = nil

        typingIndicator?.removeFromSuperview()
        typingIndicator = nil
        typingDots = []
    }

    private func createTypingRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.9).cgColor
        bubble.layer?.cornerRadius = 12
        bubble.translatesAutoresizingMaskIntoConstraints = false

        typingDots = []
        let dotSize: CGFloat = 8
        let dotSpacing: CGFloat = 6
        let totalDotsWidth = (dotSize * 3) + (dotSpacing * 2)

        for i in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
            dot.layer?.cornerRadius = dotSize / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(dot)

            let xOffset = CGFloat(i) * (dotSize + dotSpacing)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotSize),
                dot.heightAnchor.constraint(equalToConstant: dotSize),
                dot.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
                dot.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14 + xOffset),
            ])
            typingDots.append(dot)
        }

        row.addSubview(bubble)

        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.widthAnchor.constraint(equalToConstant: totalDotsWidth + 28),
            bubble.heightAnchor.constraint(equalToConstant: typingBubbleHeight),
            row.widthAnchor.constraint(equalToConstant: contentWidth - 32),
        ])

        return row
    }

    // MARK: - Ephemeral Error

    func showEphemeralError(_ message: String, relativeTo anchorView: NSView) {
        guard let wrapper = anchorView.superview else { return }

        let label = NSTextField(wrappingLabelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.alignment = .center
        label.alphaValue = 0

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.9).cgColor
        bubble.layer?.cornerRadius = 12
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.alphaValue = 0

        bubble.addSubview(label)
        wrapper.addSubview(bubble)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),

            bubble.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            bubble.topAnchor.constraint(equalTo: anchorView.bottomAnchor, constant: 8),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth - 32),
        ])

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            bubble.animator().alphaValue = 1
            label.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak bubble] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                bubble?.animator().alphaValue = 0
            }, completionHandler: {
                bubble?.removeFromSuperview()
            })
        }
    }
}
