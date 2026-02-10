import Foundation

/// Handles persistence of chat sessions across app restarts
class SessionStorage {
    static let shared = SessionStorage()

    private let sessionDirectory: URL
    private let currentSessionFile: URL
    private let maxMessages = 50  // Keep last 50 messages

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionDirectory = appSupport.appendingPathComponent("Notch/sessions", isDirectory: true)
        currentSessionFile = sessionDirectory.appendingPathComponent("current.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
    }

    /// Save messages to disk
    func save(messages: [ChatMessage]) {
        // Convert to serializable format
        let data = messages.prefix(maxMessages).map { msg -> [String: Any] in
            var dict: [String: Any] = [
                "text": msg.text,
                "isFromUser": msg.isFromUser
            ]
            if msg.isFromMind { dict["isFromMind"] = true }
            if let ctx = msg.mindContext { dict["mindContext"] = ctx }
            return dict
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else { return }

        try? jsonData.write(to: currentSessionFile)
    }

    /// Load messages from disk
    func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: currentSessionFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return json.compactMap { dict -> ChatMessage? in
            guard let text = dict["text"] as? String,
                  let isFromUser = dict["isFromUser"] as? Bool else {
                return nil
            }
            let isFromMind = dict["isFromMind"] as? Bool ?? false
            let mindContext = dict["mindContext"] as? String
            return ChatMessage(text: text, isFromUser: isFromUser, isFromMind: isFromMind, mindContext: mindContext)
        }
    }

    /// Clear current session
    func clear() {
        try? FileManager.default.removeItem(at: currentSessionFile)
    }
}
