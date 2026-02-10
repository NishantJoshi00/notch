import Foundation

/// Anthropic native memory tool implementation (memory_20250818)
/// Provides persistent memory across sessions via a file-based storage system
class MemoryTool: NotchTool {
    let name = "memory"
    let description = "Remember across conversations. Store what matters, recall what you've learned about them."

    // Memory tool uses Anthropic's native schema - we define a simplified version for our tool registry
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "enum": ["view", "create", "str_replace", "insert", "delete", "rename"],
                "description": "The operation to perform"
            ],
            "path": [
                "type": "string",
                "description": "File path relative to memories directory"
            ],
            "file_text": [
                "type": "string",
                "description": "Content for create command"
            ],
            "old_str": [
                "type": "string",
                "description": "String to find for str_replace"
            ],
            "new_str": [
                "type": "string",
                "description": "Replacement string for str_replace or text for insert"
            ],
            "insert_line": [
                "type": "integer",
                "description": "Line number for insert command (0 = start of file)"
            ],
            "new_path": [
                "type": "string",
                "description": "New path for rename command"
            ]
        ],
        "required": ["command", "path"]
    ]

    private let memoriesDirectory: URL

    init() {
        // ~/.notch/memories/
        let home = FileManager.default.homeDirectoryForCurrentUser
        memoriesDirectory = home.appendingPathComponent(".notch/memories", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
    }

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let command = input["command"] as? String,
              let path = input["path"] as? String else {
            completion(.error("Missing required parameters: command and path"))
            return
        }

        // Sanitize path to prevent directory traversal
        let sanitizedPath = path.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = memoriesDirectory.appendingPathComponent(sanitizedPath)

        switch command {
        case "view":
            handleView(fileURL: fileURL, path: sanitizedPath, completion: completion)
        case "create":
            handleCreate(fileURL: fileURL, input: input, completion: completion)
        case "str_replace":
            handleStrReplace(fileURL: fileURL, input: input, completion: completion)
        case "insert":
            handleInsert(fileURL: fileURL, input: input, completion: completion)
        case "delete":
            handleDelete(fileURL: fileURL, completion: completion)
        case "rename":
            handleRename(fileURL: fileURL, input: input, completion: completion)
        default:
            completion(.error("Unknown command: \(command)"))
        }
    }

    private func handleView(fileURL: URL, path: String, completion: @escaping (ToolResult) -> Void) {
        // If path is empty or just "/", list all files
        if path.isEmpty {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: memoriesDirectory, includingPropertiesForKeys: nil)
                let fileNames = files.map { $0.lastPathComponent }
                if fileNames.isEmpty {
                    completion(.text("No memories stored yet."))
                } else {
                    completion(.text("Memory files:\n" + fileNames.joined(separator: "\n")))
                }
            } catch {
                completion(.text("No memories stored yet."))
            }
            return
        }

        // Check if it's a directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: nil)
                    let fileNames = files.map { $0.lastPathComponent }
                    completion(.text("Files in \(path):\n" + fileNames.joined(separator: "\n")))
                } catch {
                    completion(.error("Failed to list directory: \(error.localizedDescription)"))
                }
                return
            }
        }

        // Read file content
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            completion(.text(content))
        } catch {
            completion(.error("File not found: \(path)"))
        }
    }

    private func handleCreate(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let fileText = input["file_text"] as? String else {
            completion(.error("Missing file_text for create command"))
            return
        }

        do {
            // Create parent directories if needed
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileText.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.text("Created memory: \(fileURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to create file: \(error.localizedDescription)"))
        }
    }

    private func handleStrReplace(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let oldStr = input["old_str"] as? String,
              let newStr = input["new_str"] as? String else {
            completion(.error("Missing old_str or new_str for str_replace"))
            return
        }

        do {
            var content = try String(contentsOf: fileURL, encoding: .utf8)

            // Check that old_str exists and is unique
            let occurrences = content.components(separatedBy: oldStr).count - 1
            if occurrences == 0 {
                completion(.error("old_str not found in file"))
                return
            }
            if occurrences > 1 {
                completion(.error("old_str appears \(occurrences) times - must be unique"))
                return
            }

            content = content.replacingOccurrences(of: oldStr, with: newStr)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.text("Replaced text successfully"))
        } catch {
            completion(.error("Failed to replace: \(error.localizedDescription)"))
        }
    }

    private func handleInsert(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let newStr = input["new_str"] as? String,
              let insertLine = input["insert_line"] as? Int else {
            completion(.error("Missing new_str or insert_line for insert"))
            return
        }

        do {
            var content = try String(contentsOf: fileURL, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")

            let index = max(0, min(insertLine, lines.count))
            lines.insert(newStr, at: index)

            content = lines.joined(separator: "\n")
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.text("Inserted text at line \(index)"))
        } catch {
            completion(.error("Failed to insert: \(error.localizedDescription)"))
        }
    }

    private func handleDelete(fileURL: URL, completion: @escaping (ToolResult) -> Void) {
        do {
            try FileManager.default.removeItem(at: fileURL)
            completion(.text("Deleted memory: \(fileURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to delete: \(error.localizedDescription)"))
        }
    }

    private func handleRename(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let newPath = input["new_path"] as? String else {
            completion(.error("Missing new_path for rename"))
            return
        }

        let sanitizedNewPath = newPath.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let newURL = memoriesDirectory.appendingPathComponent(sanitizedNewPath)

        do {
            try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            completion(.text("Renamed to: \(newURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to rename: \(error.localizedDescription)"))
        }
    }
}
