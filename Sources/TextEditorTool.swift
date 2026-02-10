import Foundation

/// Anthropic native text editor tool implementation (text_editor_20250728)
/// Provides file viewing and editing capabilities with safety restrictions
class TextEditorTool: NotchTool {
    let name = "str_replace_based_edit_tool"
    let description = "Read and edit files they've shared with you. Everything lives in ~/AIspace."

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "enum": ["view", "create", "str_replace", "insert"],
                "description": "The operation to perform"
            ],
            "path": [
                "type": "string",
                "description": "Absolute file path"
            ],
            "file_text": [
                "type": "string",
                "description": "Content for create command"
            ],
            "old_str": [
                "type": "string",
                "description": "String to find for str_replace (must be unique)"
            ],
            "new_str": [
                "type": "string",
                "description": "Replacement string for str_replace or text for insert"
            ],
            "insert_line": [
                "type": "integer",
                "description": "Line number for insert command (0 = start of file)"
            ],
            "view_range": [
                "type": "array",
                "items": ["type": "integer"],
                "description": "Optional [start_line, end_line] for partial view"
            ]
        ],
        "required": ["command", "path"]
    ]

    // Allowed directories - restricted sandbox
    private let allowedRoots: [URL]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let aiSpace = home.appendingPathComponent("AIspace", isDirectory: true)
        allowedRoots = [aiSpace.standardizedFileURL.resolvingSymlinksInPath()]
    }

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let command = input["command"] as? String,
              let path = input["path"] as? String else {
            completion(.error("Missing required parameters: command and path"))
            return
        }

        // Expand ~ to home directory
        let expandedPath = (path as NSString).expandingTildeInPath
        let requestedURL = URL(fileURLWithPath: expandedPath)

        // Security check
        guard let fileURL = validatedAllowedURL(for: requestedURL) else {
            completion(.error("Access denied. Can only access files in ~/AIspace"))
            return
        }

        switch command {
        case "view":
            handleView(fileURL: fileURL, input: input, completion: completion)
        case "create":
            handleCreate(fileURL: fileURL, input: input, completion: completion)
        case "str_replace":
            handleStrReplace(fileURL: fileURL, input: input, completion: completion)
        case "insert":
            handleInsert(fileURL: fileURL, input: input, completion: completion)
        default:
            completion(.error("Unknown command: \(command)"))
        }
    }

    private func validatedAllowedURL(for url: URL) -> URL? {
        // Normalize path traversal and resolve symlinks before enforcing sandbox boundaries.
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        for root in allowedRoots {
            let rootPath = root.path
            if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") {
                return resolved
            }
        }

        return nil
    }

    private func handleView(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            // Handle view_range if provided
            if let viewRange = input["view_range"] as? [Int],
               viewRange.count == 2 {
                let startLine = viewRange[0]
                let endLine = viewRange[1]

                guard startLine > 0, endLine >= startLine else {
                    completion(.error("Invalid view_range. Use [start_line, end_line] with positive values and end >= start."))
                    return
                }

                let start = startLine - 1  // Convert to 0-indexed
                let end = min(lines.count, endLine)

                if start >= lines.count {
                    completion(.error("Start line \(startLine) exceeds file length (\(lines.count) lines)"))
                    return
                }

                let selectedLines = Array(lines[start..<end])
                let numberedLines = selectedLines.enumerated().map { (idx, line) in
                    String(format: "%4d: %@", start + idx + 1, line)
                }
                completion(.text(numberedLines.joined(separator: "\n")))
            } else {
                // Return with line numbers
                let numberedLines = lines.enumerated().map { (idx, line) in
                    String(format: "%4d: %@", idx + 1, line)
                }
                // Truncate if too long
                if numberedLines.count > 500 {
                    let truncated = Array(numberedLines.prefix(500))
                    completion(.text(truncated.joined(separator: "\n") + "\n... (\(lines.count - 500) more lines)"))
                } else {
                    completion(.text(numberedLines.joined(separator: "\n")))
                }
            }
        } catch {
            completion(.error("File not found or unreadable: \(fileURL.lastPathComponent)"))
        }
    }

    private func handleCreate(fileURL: URL, input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let fileText = input["file_text"] as? String else {
            completion(.error("Missing file_text for create command"))
            return
        }

        // Check if file already exists
        if FileManager.default.fileExists(atPath: fileURL.path) {
            completion(.error("File already exists. Use str_replace to modify existing files."))
            return
        }

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileText.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.text("Created: \(fileURL.lastPathComponent)"))
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
                completion(.error("old_str appears \(occurrences) times - must be unique. Add more context."))
                return
            }

            content = content.replacingOccurrences(of: oldStr, with: newStr)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            completion(.text("Replaced text in \(fileURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to edit file: \(error.localizedDescription)"))
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
            completion(.text("Inserted text at line \(index + 1) in \(fileURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to insert: \(error.localizedDescription)"))
        }
    }
}
