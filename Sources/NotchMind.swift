import Cocoa

class NotchMind {
    private weak var appDelegate: AppDelegate?
    private var notificationManager: NotchNotificationManager { NotchNotificationManager.shared }
    private var pendingThoughts: [ScheduledThought] = []
    private let lock = NSLock()
    private var isProcessing = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    /// Called by the scheduler when thoughts fire
    func wake(with thoughts: [ScheduledThought]) {
        lock.lock()
        pendingThoughts.append(contentsOf: thoughts)
        let shouldProcess = !isProcessing
        if shouldProcess { isProcessing = true }
        lock.unlock()

        if shouldProcess {
            processPendingThoughts()
        }
    }

    // MARK: - Processing

    private func processPendingThoughts() {
        lock.lock()
        let thoughts = pendingThoughts
        pendingThoughts.removeAll()
        lock.unlock()

        guard !thoughts.isEmpty else {
            finishProcessing()
            return
        }

        guard let apiKey = appDelegate?.apiKey, !apiKey.isEmpty else {
            finishProcessing()
            return
        }

        let systemPrompt = buildMindPrompt(thoughts: thoughts)
        let messages: [[String: Any]] = [
            ["role": "user", "content": "You're awake. What's happening?"]
        ]

        callMindAPI(systemPrompt: systemPrompt, messages: messages, apiKey: apiKey)
    }

    private func finishProcessing() {
        lock.lock()
        let hasMore = !pendingThoughts.isEmpty
        if !hasMore { isProcessing = false }
        lock.unlock()

        if hasMore {
            processPendingThoughts()
        }
    }

    // MARK: - Mind Prompt

    private func buildMindPrompt(thoughts: [ScheduledThought]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy 'at' h:mm a"
        let now = formatter.string(from: Date())

        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default: timeOfDay = "night"
        }

        let thoughtsList = thoughts.enumerated().map { i, t in
            "[\(i + 1)] (\(t.source.rawValue)) \(t.content)" +
            (t.metadata.isEmpty ? "" : " [metadata: \(t.metadata)]")
        }.joined(separator: "\n")

        let scheduledInfo = NotchScheduler.shared.formattedSummary()

        let capability = NotchCapability.mind(
            time: now,
            timeOfDay: timeOfDay,
            thoughts: thoughtsList,
            scheduled: scheduledInfo,
            recentConversation: recentConversationContext(),
            memories: memoryContext()
        )

        return """
        \(NotchSoul.prompt)

        \(capability)
        """
    }

    // MARK: - Context Helpers

    private func recentConversationContext() -> String {
        guard let messages = appDelegate?.messages else { return "(no recent conversation)" }
        let recent = Array(messages.prefix(6).reversed())
        if recent.isEmpty { return "(no recent conversation)" }
        return recent.map { msg in
            "\(msg.isFromUser ? "User" : "Notch"): \(msg.text)"
        }.joined(separator: "\n")
    }

    private func memoryContext() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let memoriesDir = home.appendingPathComponent(".notch/memories")

        // Read user memory file
        let userMemory = memoriesDir.appendingPathComponent("user")
        if let content = try? String(contentsOf: userMemory, encoding: .utf8) {
            return content
        }
        return "(no user memories stored)"
    }

    // MARK: - Mind API Call

    // Mind-exclusive tools (not available in conversation)
    private let mindOnlyTools: [[String: Any]] = [
        [
            "name": "send_message",
            "description": "Speak to them. They'll see it now or get notified if they're away.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "message": ["type": "string", "description": "The message to send"],
                    "reason": ["type": "string", "description": "Brief note on why you're sending this — helps your future self remember"]
                ],
                "required": ["message", "reason"]
            ] as [String: Any]
        ],
        [
            "name": "stay_silent",
            "description": "Stay quiet. Not everything needs a response.",
            "input_schema": [
                "type": "object",
                "properties": [:] as [String: Any]
            ] as [String: Any]
        ]
    ]

    /// Build the full tool list: shared tools + mind-only tools
    private func buildToolDefinitions() -> [[String: Any]] {
        var tools: [[String: Any]] = []

        // Shared tools from AppDelegate (same ones the conversation uses, minus end_conversation)
        if let shared = appDelegate?.sharedTools {
            for tool in shared {
                tools.append([
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema
                ])
            }
        }

        // Mind-exclusive tools
        tools.append(contentsOf: mindOnlyTools)

        return tools
    }

    private func callMindAPI(systemPrompt: String, messages: [[String: Any]], apiKey: String) {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 2048,
            "system": systemPrompt,
            "tools": buildToolDefinitions(),
            "messages": messages
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }

            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let stopReason = json["stop_reason"] as? String else {
                self.finishProcessing()
                return
            }

            if stopReason == "tool_use" {
                self.handleMindToolCalls(
                    content: content,
                    previousMessages: messages,
                    apiKey: apiKey,
                    systemPrompt: systemPrompt
                )
            } else {
                self.finishProcessing()
            }
        }.resume()
    }

    // MARK: - Mind Tool Handling

    private func handleMindToolCalls(content: [[String: Any]], previousMessages: [[String: Any]],
                                     apiKey: String, systemPrompt: String) {
        var nextMessages = previousMessages
        nextMessages.append(["role": "assistant", "content": content])

        // Extract tool_use blocks
        var toolUseBlocks: [(id: String, name: String, input: [String: Any])] = []
        for block in content {
            if let type = block["type"] as? String, type == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                let input = block["input"] as? [String: Any] ?? [:]
                toolUseBlocks.append((id: id, name: name, input: input))
            }
        }

        let group = DispatchGroup()
        var toolResults: [(id: String, result: [String: Any])] = []
        let resultsLock = NSLock()

        for toolUse in toolUseBlocks {
            switch toolUse.name {
            // Mind-only tools — handled inline
            case "send_message":
                if let message = toolUse.input["message"] as? String {
                    let reason = toolUse.input["reason"] as? String
                    deliverMessage(message, context: reason)
                    resultsLock.lock()
                    toolResults.append((id: toolUse.id, result: [
                        "type": "tool_result", "tool_use_id": toolUse.id, "content": "Message sent."
                    ]))
                    resultsLock.unlock()
                }

            case "stay_silent":
                resultsLock.lock()
                toolResults.append((id: toolUse.id, result: [
                    "type": "tool_result", "tool_use_id": toolUse.id, "content": "OK, staying silent."
                ]))
                resultsLock.unlock()

            // Shared tools — delegate to NotchTool.execute()
            default:
                if let tool = appDelegate?.sharedTools.first(where: { $0.name == toolUse.name }) {
                    group.enter()
                    tool.execute(input: toolUse.input) { result in
                        var resultBlock: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": toolUse.id
                        ]
                        switch result {
                        case .text(let text):
                            resultBlock["content"] = text
                        case .image(let data, let mediaType):
                            resultBlock["content"] = [[
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": data.base64EncodedString()
                                ]
                            ]]
                        case .error(let error):
                            resultBlock["content"] = "Error: \(error)"
                            resultBlock["is_error"] = true
                        }
                        resultsLock.lock()
                        toolResults.append((id: toolUse.id, result: resultBlock))
                        resultsLock.unlock()
                        group.leave()
                    }
                } else {
                    resultsLock.lock()
                    toolResults.append((id: toolUse.id, result: [
                        "type": "tool_result", "tool_use_id": toolUse.id,
                        "content": "Unknown tool", "is_error": true
                    ]))
                    resultsLock.unlock()
                }
            }
        }

        group.notify(queue: .global(qos: .utility)) { [weak self] in
            let results = toolResults.map { $0.result }
            nextMessages.append(["role": "user", "content": results])
            self?.callMindAPI(systemPrompt: systemPrompt, messages: nextMessages, apiKey: apiKey)
        }
    }

    // MARK: - Message Delivery

    private func deliverMessage(_ message: String, context: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let appDelegate = self?.appDelegate else { return }

            // Insert as a regular Notch message with context for continuity
            appDelegate.insertMindMessage(message, context: context)

            // If the input window is visible, reload it. Otherwise, notify.
            if appDelegate.isInputWindowVisible {
                appDelegate.reloadInputWindow()
            } else {
                self?.notificationManager.sendNotification(body: message)
            }
        }
    }
}
