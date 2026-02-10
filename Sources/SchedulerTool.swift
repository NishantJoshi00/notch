import Foundation

class SchedulerTool: NotchTool {
    let name = "scheduler"
    let description = "Track time for them. Set reminders, check what's ahead, let go of what's past."

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "enum": ["schedule", "list", "cancel"],
                "description": "Operation: schedule a new reminder, list existing ones, or cancel one"
            ],
            "content": [
                "type": "string",
                "description": "What to remind about (for schedule command)"
            ],
            "fire_at": [
                "type": "string",
                "description": "ISO 8601 datetime for when to fire, e.g. 2025-01-15T15:00:00 (for schedule command)"
            ],
            "delay_minutes": [
                "type": "number",
                "description": "Alternative to fire_at: minutes from now (for schedule command)"
            ],
            "thought_id": [
                "type": "string",
                "description": "UUID or UUID prefix of reminder to cancel (for cancel command)"
            ]
        ],
        "required": ["command"]
    ]

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let command = input["command"] as? String else {
            completion(.error("Missing command"))
            return
        }

        switch command {
        case "schedule":
            handleSchedule(input: input, completion: completion)
        case "list":
            handleList(completion: completion)
        case "cancel":
            handleCancel(input: input, completion: completion)
        default:
            completion(.error("Unknown command: \(command)"))
        }
    }

    private func handleSchedule(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let content = input["content"] as? String else {
            completion(.error("Missing content"))
            return
        }

        let fireDate: Date
        if let isoString = input["fire_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Try with fractional seconds first, then without
            if let parsed = formatter.date(from: isoString) {
                fireDate = parsed
            } else {
                let basic = ISO8601DateFormatter()
                if let parsed = basic.date(from: isoString) {
                    fireDate = parsed
                } else {
                    completion(.error("Invalid date format. Use ISO 8601, e.g. 2025-01-15T15:00:00Z"))
                    return
                }
            }
        } else if let delayMinutes = input["delay_minutes"] as? Double {
            fireDate = Date().addingTimeInterval(delayMinutes * 60)
        } else {
            completion(.error("Provide either fire_at or delay_minutes"))
            return
        }

        let thought = ScheduledThought(
            content: content,
            source: .userReminder,
            fireDate: fireDate
        )
        NotchScheduler.shared.schedule(thought)

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        completion(.text("Scheduled: \"\(content)\" for \(formatter.string(from: fireDate))"))
    }

    private func handleList(completion: @escaping (ToolResult) -> Void) {
        let summary = NotchScheduler.shared.formattedSummary()
        if summary == "(nothing scheduled)" {
            completion(.text("Nothing scheduled."))
        } else {
            completion(.text("Scheduled:\n\(summary)"))
        }
    }

    private func handleCancel(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let idStr = input["thought_id"] as? String else {
            completion(.error("Missing thought_id"))
            return
        }

        if let match = NotchScheduler.shared.findThought(idPrefix: idStr) {
            NotchScheduler.shared.cancel(id: match.id)
            completion(.text("Cancelled: \"\(match.content)\""))
        } else {
            completion(.error("No reminder found with id \(idStr)"))
        }
    }
}
