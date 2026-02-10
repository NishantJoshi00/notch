import Foundation

/// Anthropic native memory tool implementation (memory_20250818)
/// Provides persistent memory across sessions via a file-based storage system
/// Also provides access to ~/.notch/prompts/ for self-modifying behavior
class MemoryTool: NotchTool {
    let name = "memory"
    let description = "Remember across conversations. Store what matters, recall what you've learned. Search your past. Journal observations. Edit your own operating prompts (not soul)."

    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "enum": ["view", "create", "str_replace", "insert", "delete", "rename", "journal", "search"],
                "description": "The operation to perform. 'journal' appends timestamped entries to daily log. 'search' finds content across all memories."
            ],
            "path": [
                "type": "string",
                "description": "File path relative to memories directory. Prefix with 'prompts/' to access ~/.notch/prompts/ (your editable operating instructions). Not required for journal or search."
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
            ],
            "entry": [
                "type": "string",
                "description": "For journal command: the observation or note to log"
            ],
            "date": [
                "type": "string",
                "description": "For journal command: read a specific day's journal (YYYY-MM-DD). Omit to append to today."
            ],
            "query": [
                "type": "string",
                "description": "For search command: what to search for across all memories"
            ]
        ],
        "required": ["command"]
    ]

    private let memoriesDirectory: URL
    private let promptsDirectory: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        memoriesDirectory = home.appendingPathComponent(".notch/memories", isDirectory: true)
        promptsDirectory = home.appendingPathComponent(".notch/prompts", isDirectory: true)

        try? FileManager.default.createDirectory(at: memoriesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)
    }

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let command = input["command"] as? String else {
            completion(.error("Missing required parameter: command"))
            return
        }

        // Journal and search don't require path
        if command == "journal" {
            handleJournal(input: input, completion: completion)
            return
        }
        if command == "search" {
            handleSearch(input: input, completion: completion)
            return
        }

        guard let path = input["path"] as? String else {
            completion(.error("Missing required parameter: path"))
            return
        }

        // Route to correct directory based on path prefix
        let (fileURL, sanitizedPath) = resolveURL(for: path)

        // Soul guard: reject writes to anything with "soul" in the path
        if command != "view" && sanitizedPath.lowercased().contains("soul") {
            completion(.error("Cannot modify soul. That's immutable."))
            return
        }

        switch command {
        case "view":
            handleView(fileURL: fileURL, path: sanitizedPath, isPrompts: path.hasPrefix("prompts/") || path == "prompts", completion: completion)
        case "create":
            handleCreate(fileURL: fileURL, input: input, completion: completion)
        case "str_replace":
            handleStrReplace(fileURL: fileURL, input: input, completion: completion)
        case "insert":
            handleInsert(fileURL: fileURL, input: input, completion: completion)
        case "delete":
            handleDelete(fileURL: fileURL, completion: completion)
        case "rename":
            handleRename(fileURL: fileURL, input: input, basePath: path, completion: completion)
        default:
            completion(.error("Unknown command: \(command)"))
        }
    }

    // MARK: - Path Resolution

    /// Routes "prompts/..." paths to ~/.notch/prompts/, everything else to ~/.notch/memories/
    private func resolveURL(for path: String) -> (URL, String) {
        let sanitized = path.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if sanitized.hasPrefix("prompts/") || sanitized == "prompts" {
            let subpath = sanitized.hasPrefix("prompts/")
                ? String(sanitized.dropFirst("prompts/".count))
                : ""
            let url = subpath.isEmpty
                ? promptsDirectory
                : promptsDirectory.appendingPathComponent(subpath)
            return (url, sanitized)
        }

        let url = sanitized.isEmpty
            ? memoriesDirectory
            : memoriesDirectory.appendingPathComponent(sanitized)
        return (url, sanitized)
    }

    // MARK: - Journal

    private func handleJournal(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        let journalDir = memoriesDirectory.appendingPathComponent("journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        // If a date is provided and no entry, read that day's journal
        if let date = input["date"] as? String, input["entry"] == nil {
            let fileURL = journalDir.appendingPathComponent("\(date).md")
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                completion(.text(content))
            } else {
                completion(.text("No journal entry for \(date)."))
            }
            return
        }

        // Append entry to today's journal
        guard let entry = input["entry"] as? String else {
            // No entry, no date — show today's journal
            let today = todayString()
            let fileURL = journalDir.appendingPathComponent("\(today).md")
            if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                completion(.text(content))
            } else {
                completion(.text("No journal entries today."))
            }
            return
        }

        let today = todayString()
        let fileURL = journalDir.appendingPathComponent("\(today).md")

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(entry)\n"

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            completion(.text("Logged."))
        } catch {
            completion(.error("Failed to journal: \(error.localizedDescription)"))
        }
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Search

    private func handleSearch(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        guard let query = input["query"] as? String, !query.isEmpty else {
            completion(.error("Missing query for search"))
            return
        }

        let keywords = query.lowercased().split(separator: " ").map(String.init)
        var results: [(path: String, score: Double, excerpt: String)] = []
        let today = todayString()

        // Collect all files recursively
        let files = allFilesRecursive(in: memoriesDirectory)

        for fileURL in files {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let lowered = content.lowercased()

            // Score: keyword hits
            var hitCount = 0
            for keyword in keywords {
                var searchRange = lowered.startIndex..<lowered.endIndex
                while let range = lowered.range(of: keyword, range: searchRange) {
                    hitCount += 1
                    searchRange = range.upperBound..<lowered.endIndex
                }
            }

            guard hitCount > 0 else { continue }

            var score = Double(hitCount)

            // Recency bonus for journal files
            let relativePath = fileURL.path.replacingOccurrences(of: memoriesDirectory.path + "/", with: "")
            if relativePath.hasPrefix("journal/") {
                let filename = fileURL.deletingPathExtension().lastPathComponent
                if filename == today {
                    score *= 3.0
                } else if let daysAgo = daysBetween(dateString: filename, and: today) {
                    if daysAgo == 1 { score *= 2.0 }
                    else if daysAgo <= 7 { score *= 1.5 }
                }
            }

            // Extract best matching excerpt
            let excerpt = extractExcerpt(from: content, keywords: keywords)
            results.append((path: relativePath, score: score, excerpt: excerpt))
        }

        results.sort { $0.score > $1.score }
        let top = results.prefix(5)

        if top.isEmpty {
            completion(.text("Nothing found for: \(query)"))
        } else {
            let output = top.map { "[\($0.path)] (score: \(Int($0.score)))\n\($0.excerpt)" }.joined(separator: "\n\n")
            completion(.text(output))
        }
    }

    private func allFilesRecursive(in directory: URL) -> [URL] {
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return files }

        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if !isDir.boolValue {
                files.append(fileURL)
            }
        }
        return files
    }

    private func extractExcerpt(from content: String, keywords: [String]) -> String {
        let lines = content.components(separatedBy: "\n")
        var bestLine = ""
        var bestScore = 0

        for line in lines {
            let lowered = line.lowercased()
            var score = 0
            for keyword in keywords {
                if lowered.contains(keyword) { score += 1 }
            }
            if score > bestScore {
                bestScore = score
                bestLine = line
            }
        }

        let trimmed = bestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 200 {
            return String(trimmed.prefix(200)) + "..."
        }
        return trimmed
    }

    private func daysBetween(dateString: String, and today: String) -> Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let d1 = formatter.date(from: dateString),
              let d2 = formatter.date(from: today) else { return nil }
        return Calendar.current.dateComponents([.day], from: d1, to: d2).day
    }

    // MARK: - Standard Commands

    private func handleView(fileURL: URL, path: String, isPrompts: Bool, completion: @escaping (ToolResult) -> Void) {
        let baseDir = isPrompts ? promptsDirectory : memoriesDirectory
        let effectivePath = isPrompts
            ? (path.hasPrefix("prompts/") ? String(path.dropFirst("prompts/".count)) : "")
            : path

        if effectivePath.isEmpty {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
                let fileNames = files.map { $0.lastPathComponent }
                if fileNames.isEmpty {
                    completion(.text(isPrompts ? "No prompt files yet." : "No memories stored yet."))
                } else {
                    let label = isPrompts ? "Prompt files" : "Memory files"
                    completion(.text("\(label):\n" + fileNames.joined(separator: "\n")))
                }
            } catch {
                completion(.text(isPrompts ? "No prompt files yet." : "No memories stored yet."))
            }
            return
        }

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
            completion(.text("Deleted: \(fileURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to delete: \(error.localizedDescription)"))
        }
    }

    private func handleRename(fileURL: URL, input: [String: Any], basePath: String, completion: @escaping (ToolResult) -> Void) {
        guard let newPath = input["new_path"] as? String else {
            completion(.error("Missing new_path for rename"))
            return
        }

        let (newURL, _) = resolveURL(for: newPath)

        // Soul guard on destination too
        if newPath.lowercased().contains("soul") {
            completion(.error("Cannot rename to a soul path. That's immutable."))
            return
        }

        do {
            try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            completion(.text("Renamed to: \(newURL.lastPathComponent)"))
        } catch {
            completion(.error("Failed to rename: \(error.localizedDescription)"))
        }
    }
}
