import Foundation

class EndConversationTool: NotchTool {
    let name = "end_conversation"
    let description = "End things when they're clearly done. Bye, thanks, talk later."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:],
        "required": []
    ]

    private let onEnd: () -> Void

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.onEnd()
        }
        completion(.text("done"))
    }
}
