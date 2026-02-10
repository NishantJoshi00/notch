import Cocoa

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let imageRect = NSRect(origin: .zero, size: image.size)
        imageRect.fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

struct ChatMessage {
    let text: String
    let isFromUser: Bool
    let isFromMind: Bool
    let mindContext: String?  // why the mind sent this (the triggering thought)

    init(text: String, isFromUser: Bool, isFromMind: Bool = false, mindContext: String? = nil) {
        self.text = text
        self.isFromUser = isFromUser
        self.isFromMind = isFromMind
        self.mindContext = mindContext
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var inputWindow: InputBarWindow?
    private var eventTap: CFMachPort?

    private var lastRightOptionTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.3

    // Chat messages storage (persists across input bar open/close)
    private(set) var messages: [ChatMessage] = []

    // Mind system
    private var mind: NotchMind?
    private var systemEventMonitor: SystemEventMonitor?

    // Shared tools — available to both conversation and mind
    private(set) lazy var sharedTools: [NotchTool] = {
        let camera = CameraTool()
        camera.uiCaptureHandler = { [weak self] completion in
            guard let window = self?.inputWindow, window.isVisible else {
                return false  // no window — fall back to direct capture
            }
            window.showCameraCapture(completion: completion)
            return true
        }
        return [ScreenshotTool(), MemoryTool(), TextEditorTool(), SchedulerTool(), camera]
    }()

    // Conversation-only tools (not available to the mind)
    private lazy var conversationOnlyTools: [NotchTool] = [
        EndConversationTool { [weak self] in
            self?.clearMessages()
            self?.inputWindow?.close()
            self?.inputWindow = nil
        }
    ]

    // All tools for the conversation API
    private lazy var tools: [NotchTool] = sharedTools + conversationOnlyTools

    // API key stored in UserDefaults
    private let apiKeyKey = "AnthropicAPIKey"
    private(set) var apiKey: String? {
        get { UserDefaults.standard.string(forKey: apiKeyKey) }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyKey) }
    }

    /// Whether the input window is currently visible (used by NotchMind)
    var isInputWindowVisible: Bool {
        inputWindow?.isVisible ?? false
    }

    /// Reload the input window's messages (used by NotchMind for background message delivery)
    func reloadInputWindow() {
        inputWindow?.reloadMessages()
    }

    /// Insert a message from the mind (bypasses API call)
    func insertMindMessage(_ text: String, context: String? = nil) {
        messages.insert(ChatMessage(text: text, isFromUser: false, isFromMind: true, mindContext: context), at: 0)
        SessionStorage.shared.save(messages: messages)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Restore previous session
        messages = SessionStorage.shared.load()

        setupMainMenu()
        setupStatusItem()
        setupEventTap()

        // Initialize the mind
        mind = NotchMind(appDelegate: self)
        NotchScheduler.shared.onThoughtsFired = { [weak self] thoughts in
            self?.mind?.wake(with: thoughts)
        }
        NotchScheduler.shared.startCaringCycle()

        // System event monitoring
        systemEventMonitor = SystemEventMonitor()
        systemEventMonitor?.onSystemEvent = { [weak self] thought in
            self?.mind?.wake(with: [thought])
        }
        systemEventMonitor?.start()

        // Boot turn — let the mind orient itself on launch
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            let bootThought = ScheduledThought(
                content: "You just came online. Orient yourself — check what happened since last time.",
                source: .boot,
                fireDate: Date()
            )
            self?.mind?.wake(with: [bootThought])
        }

        // Notifications
        NotchNotificationManager.shared.requestPermission()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNotificationTap),
            name: .notchNotificationTapped, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save session on quit
        SessionStorage.shared.save(messages: messages)

        // Kill any running quests
        QuestManager.shared.killAll()

        // Shut down the mind
        NotchScheduler.shared.stopCaringCycle()
        systemEventMonitor?.stop()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (required for copy/paste to work)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "Notch")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Set API Key...", action: #selector(showAPIKeyDialog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Chat", action: #selector(clearChat), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // Quest submenu
        let questItem = NSMenuItem(title: "Active Quests", action: nil, keyEquivalent: "")
        let questMenu = NSMenu()
        questItem.submenu = questMenu
        menu.addItem(questItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showAPIKeyDialog() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set API Key"
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.center()

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))

        // Icon
        let iconView = NSImageView(frame: NSRect(x: 160, y: 120, width: 40, height: 40))
        if let sparkleImage = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude") {
            let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
            if let configuredImage = sparkleImage.withSymbolConfiguration(config) {
                iconView.image = configuredImage.tinted(with: .systemPink)
            }
        }
        contentView.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: "Enter Anthropic API Key")
        titleLabel.frame = NSRect(x: 20, y: 95, width: 320, height: 20)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        contentView.addSubview(titleLabel)

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Your API key will be stored locally.")
        subtitleLabel.frame = NSRect(x: 20, y: 72, width: 320, height: 16)
        subtitleLabel.alignment = .center
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        contentView.addSubview(subtitleLabel)

        // Input field
        let input = NSTextField(frame: NSRect(x: 30, y: 40, width: 300, height: 24))
        input.placeholderString = "sk-ant-..."
        if let existing = apiKey {
            input.stringValue = existing
        }
        contentView.addSubview(input)

        // Save button
        let saveButton = NSButton(frame: NSRect(x: 200, y: 8, width: 80, height: 28))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        // Cancel button
        let cancelButton = NSButton(frame: NSRect(x: 115, y: 8, width: 80, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        window.contentView = contentView

        // Button actions
        saveButton.target = self
        saveButton.action = #selector(saveAPIKey(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelAPIKey(_:))

        // Store references
        apiKeyWindow = window
        apiKeyInput = input

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var apiKeyWindow: NSPanel?
    private var apiKeyInput: NSTextField?

    @objc private func saveAPIKey(_ sender: Any) {
        if let key = apiKeyInput?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            apiKey = key
        }
        apiKeyWindow?.close()
        apiKeyWindow = nil
        apiKeyInput = nil
    }

    @objc private func cancelAPIKey(_ sender: Any) {
        apiKeyWindow?.close()
        apiKeyWindow = nil
        apiKeyInput = nil
    }

    @discardableResult
    func addMessage(_ text: String, isFromUser: Bool) -> Bool {
        // Check API key before adding user message
        if isFromUser {
            guard let key = apiKey, !key.isEmpty else {
                inputWindow?.showEphemeralError("Please set your API key first (click menu bar icon).")
                inputWindow?.shakeInputBar()
                return false
            }
        }

        messages.insert(ChatMessage(text: text, isFromUser: isFromUser), at: 0)

        // Auto-save session
        SessionStorage.shared.save(messages: messages)

        // Call Claude API after user message
        if isFromUser {
            callClaudeAPI(userMessage: text)
        }
        return true
    }

    // Soul + Capability = system prompt (computed so it picks up disk edits at runtime)
    private var systemPrompt: String {
        """
        \(NotchSoul.prompt)

        \(NotchCapability.conversation)
        """
    }

    /// Detect queries that benefit from extended thinking
    private func queryNeedsThinking(_ query: String) -> Bool {
        let thinkingKeywords = [
            "analyze", "debug", "architecture", "design", "explain how",
            "compare", "tradeoffs", "trade-offs", "pros and cons",
            "step by step", "break down", "walk through",
            "what's wrong with", "why isn't", "why doesn't",
            "complex", "complicated", "deeply"
        ]

        let lowered = query.lowercased()
        return thinkingKeywords.contains { lowered.contains($0) }
    }

    private func callClaudeAPI(userMessage: String) {
        guard let apiKey = apiKey, !apiKey.isEmpty else { return }

        // Show typing indicator
        DispatchQueue.main.async { [weak self] in
            self?.inputWindow?.showTypingIndicator()
        }

        // Build initial conversation history (reverse since we store newest first)
        let historyMessages: [[String: Any]] = messages.reversed().prefix(20).map { msg in
            if msg.isFromMind {
                // Mind messages are things YOU sent proactively — own them
                let context = msg.mindContext.map { " — \($0)" } ?? ""
                return [
                    "role": "assistant",
                    "content": "[earlier\(context)] \(msg.text)"
                ]
            }
            return ["role": msg.isFromUser ? "user" : "assistant", "content": msg.text]
        }

        // Start the API loop
        continueAPILoop(conversationMessages: Array(historyMessages), apiKey: apiKey)
    }

    private func continueAPILoop(conversationMessages: [[String: Any]], apiKey: String) {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("web-fetch-2025-09-10,context-management-2025-06-27", forHTTPHeaderField: "anthropic-beta")

        // Build tool definitions
        var toolDefinitions: [[String: Any]] = [
            // Server-side tools
            [
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 3
            ],
            [
                "type": "web_fetch_20250910",
                "name": "web_fetch",
                "max_uses": 3
            ]
        ]

        // Add client-side tools from registry
        for tool in tools {
            toolDefinitions.append([
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema
            ])
        }

        var body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 4096,
            "system": systemPrompt,
            "tools": toolDefinitions,
            "messages": conversationMessages
        ]

        // Add context management to prevent context bloat
        body["context_management"] = [
            "edits": [[
                "type": "clear_tool_uses_20250919",
                "trigger": ["type": "input_tokens", "value": 100000],
                "keep": ["type": "tool_uses", "value": 3],
                "exclude_tools": ["memory"]
            ]]
        ]

        // Enable extended thinking for complex queries
        if let lastMsg = conversationMessages.last,
           let content = lastMsg["content"] as? String,
           queryNeedsThinking(content) {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": 3072
            ]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.finishWithError("Couldn't connect: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                self.finishWithError("No response")
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finishWithError("Bad response format")
                    return
                }

                if let errorInfo = json["error"] as? [String: Any],
                   let errorMessage = errorInfo["message"] as? String {
                    self.finishWithError(errorMessage)
                    return
                }

                guard let content = json["content"] as? [[String: Any]],
                      let stopReason = json["stop_reason"] as? String else {
                    self.finishWithError("Unexpected response")
                    return
                }

                // Check if we need to handle tool calls
                if stopReason == "tool_use" {
                    self.handleToolCalls(
                        content: content,
                        conversationMessages: conversationMessages,
                        apiKey: apiKey
                    )
                } else {
                    // Extract final text response
                    self.extractAndFinish(content: content)
                }
            } catch {
                self.finishWithError("Parse error")
            }
        }.resume()
    }

    private func handleToolCalls(
        content: [[String: Any]],
        conversationMessages: [[String: Any]],
        apiKey: String
    ) {
        // Find all tool_use blocks
        var toolUseBlocks: [(id: String, name: String, input: [String: Any])] = []

        for block in content {
            if let blockType = block["type"] as? String,
               blockType == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                let input = block["input"] as? [String: Any] ?? [:]
                toolUseBlocks.append((id: id, name: name, input: input))
            }
        }

        guard !toolUseBlocks.isEmpty else {
            extractAndFinish(content: content)
            return
        }

        // Extract any text that came before the tool calls and add as a message
        var preToolText = ""
        for block in content {
            if let blockType = block["type"] as? String {
                if blockType == "tool_use" {
                    break // Stop at first tool use
                }
                if blockType == "text", let text = block["text"] as? String {
                    preToolText += text
                }
            }
        }

        if !preToolText.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.messages.insert(ChatMessage(text: preToolText, isFromUser: false), at: 0)
                self?.inputWindow?.reloadMessages()
            }
        }

        // Execute tools and collect results
        let group = DispatchGroup()
        var toolResults: [(id: String, result: ToolResult)] = []
        let resultsLock = NSLock()

        for toolUse in toolUseBlocks {
            // Show tool indicator (pop in)
            DispatchQueue.main.async { [weak self] in
                self?.inputWindow?.showToolIndicator(for: toolUse.name)
            }

            // Find the tool in our registry
            guard let tool = tools.first(where: { $0.name == toolUse.name }) else {
                resultsLock.lock()
                toolResults.append((id: toolUse.id, result: .error("Unknown tool: \(toolUse.name)")))
                resultsLock.unlock()
                continue
            }

            group.enter()
            tool.execute(input: toolUse.input) { result in
                resultsLock.lock()
                toolResults.append((id: toolUse.id, result: result))
                resultsLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            // Hide tool indicator (pop out)
            self?.inputWindow?.hideToolIndicator()
            guard let self = self else { return }

            // Build the next messages array
            var nextMessages = conversationMessages

            // Add assistant message with the tool use
            nextMessages.append([
                "role": "assistant",
                "content": content
            ])

            // Add tool results as user message
            var toolResultBlocks: [[String: Any]] = []
            for (id, result) in toolResults {
                var resultBlock: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": id
                ]

                switch result {
                case .text(let text):
                    resultBlock["content"] = text
                case .image(let data, let mediaType):
                    resultBlock["content"] = [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": mediaType,
                                "data": data.base64EncodedString()
                            ]
                        ]
                    ]
                case .error(let error):
                    resultBlock["content"] = "Error: \(error)"
                    resultBlock["is_error"] = true
                }

                toolResultBlocks.append(resultBlock)
            }

            nextMessages.append([
                "role": "user",
                "content": toolResultBlocks
            ])

            // Continue the loop
            self.continueAPILoop(conversationMessages: nextMessages, apiKey: apiKey)
        }
    }

    private func extractAndFinish(content: [[String: Any]]) {
        var responseText = ""
        for block in content {
            if let blockType = block["type"] as? String,
               blockType == "text",
               let text = block["text"] as? String {
                responseText += text
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inputWindow?.hideTypingIndicator()

            // Only add message if there's actual text (silent finish if just tool use)
            if !responseText.isEmpty {
                self.messages.insert(ChatMessage(text: responseText, isFromUser: false), at: 0)
                SessionStorage.shared.save(messages: self.messages)
                self.inputWindow?.reloadMessages()
            }
        }
    }

    private func finishWithError(_ error: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inputWindow?.hideTypingIndicator()
            self.messages.insert(ChatMessage(text: error, isFromUser: false), at: 0)
            SessionStorage.shared.save(messages: self.messages)
            self.inputWindow?.reloadMessages()
        }
    }

    @objc private func clearChat() {
        clearMessages()
    }

    func clearMessages() {
        // If there's conversation worth saving, let the mind journal it first
        let hasConversation = messages.contains { $0.isFromUser }
        if hasConversation {
            let summary = messages.prefix(20).reversed().map { msg in
                "\(msg.isFromUser ? "User" : "Notch"): \(msg.text)"
            }.joined(separator: "\n")

            let saveThought = ScheduledThought(
                content: "Session being cleared. Conversation to save:\n\(summary)",
                source: .sessionSave,
                fireDate: Date()
            )
            mind?.wake(with: [saveThought])
        }

        messages.removeAll()
        SessionStorage.shared.clear()
        inputWindow?.reloadMessages()
    }

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Check Accessibility permissions in System Preferences.")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .flagsChanged {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Right Option key code is 61
            let isRightOption = keyCode == 61
            let optionPressed = flags.contains(.maskAlternate)

            if isRightOption && optionPressed {
                let now = Date()

                if let lastTime = lastRightOptionTime,
                   now.timeIntervalSince(lastTime) < doubleTapThreshold {
                    // Double tap detected
                    lastRightOptionTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.toggleInputBar()
                    }
                } else {
                    lastRightOptionTime = now
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func toggleInputBar() {
        if let window = inputWindow, window.isVisible {
            window.close()
            inputWindow = nil
        } else {
            showInputBar()
        }
    }

    private func showInputBar() {
        inputWindow = InputBarWindow(appDelegate: self)
        inputWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        systemEventMonitor?.recordActivity()
    }

    @objc private func handleNotificationTap() {
        showInputBar()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func killQuest(_ sender: NSMenuItem) {
        guard let questId = sender.representedObject as? String else { return }
        QuestManager.shared.cancel(id: questId)
    }
}

// MARK: - NSMenuDelegate (rebuild quest submenu dynamically)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Find the quest submenu and rebuild it
        guard let questItem = menu.items.first(where: { $0.title == "Active Quests" }),
              let questMenu = questItem.submenu else { return }

        questMenu.removeAllItems()

        let active = QuestManager.shared.list()
        if active.isEmpty {
            let noQuests = NSMenuItem(title: "(no active quests)", action: nil, keyEquivalent: "")
            noQuests.isEnabled = false
            questMenu.addItem(noQuests)
        } else {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.minute, .second]
            formatter.unitsStyle = .abbreviated

            for quest in active {
                let elapsed = formatter.string(from: quest.startedAt, to: Date()) ?? "?"
                let goalPreview = quest.goal.prefix(40) + (quest.goal.count > 40 ? "..." : "")
                let title = "\"\(goalPreview)\" — \(elapsed)"

                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                questMenu.addItem(item)

                let killItem = NSMenuItem(title: "  Kill", action: #selector(killQuest(_:)), keyEquivalent: "")
                killItem.representedObject = quest.id
                killItem.target = self
                questMenu.addItem(killItem)
            }
        }

        if !QuestManager.shared.isVMReady {
            questMenu.addItem(NSMenuItem.separator())
            let vmNote = NSMenuItem(title: "(VM not built — run scripts/build-quest-vm.sh)", action: nil, keyEquivalent: "")
            vmNote.isEnabled = false
            questMenu.addItem(vmNote)
        }
    }
}
