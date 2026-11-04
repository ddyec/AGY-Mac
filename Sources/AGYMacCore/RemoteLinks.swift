import Foundation

public struct ArtifactReference: Identifiable, Hashable {
    public let path: String; public let name: String; public let mime: String
    public var id: String { path }
    public init(path: String, name: String, mime: String) { self.path = path; self.name = name; self.mime = mime }
    public var image: Bool { mime.hasPrefix("image/") || FileRules.isImage(name) || FileRules.isImage(path) }
}

public struct ToolRowSummary: Identifiable, Equatable {
    public let id: String
    public let action: String
    public let target: String
    public let status: String
    public let icon: String
    public let isError: Bool
    public let isRunning: Bool
    public let details: String
}

public struct TurnProcessSummary: Equatable {
    public let commandCount: Int
    public let writtenFileCount: Int
    public let readFileCount: Int
    public let otherToolCount: Int
    public let stepNotes: [String]
    public let thinkings: [String]
    public let rounds: [String]
    public let toolRows: [ToolRowSummary]
    public let isRunning: Bool
    public let hasError: Bool

    public var isEmpty: Bool {
        commandCount == 0 && writtenFileCount == 0 && readFileCount == 0 && otherToolCount == 0 && stepNotes.isEmpty && thinkings.isEmpty && toolRows.isEmpty
    }

    public var statsText: String {
        var parts: [String] = []
        if commandCount > 0 { parts.append("运行了 \(commandCount) 次指令") }
        if writtenFileCount > 0 { parts.append("写入了 \(writtenFileCount) 个文件") }
        if readFileCount > 0 { parts.append("读取了 \(readFileCount) 个文件") }
        if otherToolCount > 0 && parts.isEmpty { parts.append("调用了 \(otherToolCount) 项工具") }
        return parts.joined(separator: " · ")
    }

    public var headerTitle: String {
        let prefix = isRunning ? "正在思考与执行" : (hasError ? "思考摘要 · 含异常" : "思考摘要")
        let stats = statsText
        if !stats.isEmpty {
            return prefix + " · " + stats
        }
        let count = max(1, rounds.count)
        return prefix + " · 共 \(count) 步推理"
    }

    public var foldedToolsTitle: String {
        let stats = statsText
        if !stats.isEmpty {
            return "已折叠工具调用 · " + stats
        }
        return "已折叠 \(toolRows.count) 项工具调用"
    }

    public func completedTitle(durationSeconds: Int?) -> String {
        let sec = durationSeconds ?? estimatedSeconds
        let durationLabel: String
        if sec >= 60 {
            let m = sec / 60
            let s = sec % 60
            durationLabel = s > 0 ? "已工作 \(m) 分 \(s) 秒" : "已工作 \(m) 分钟"
        } else {
            durationLabel = "已工作 \(max(1, sec)) 秒"
        }
        let stats = statsText
        return stats.isEmpty ? durationLabel : "\(durationLabel) · \(stats)"
    }

    public var estimatedSeconds: Int {
        max(2, commandCount * 4 + writtenFileCount * 3 + readFileCount * 1 + rounds.count * 2)
    }
}

public struct FileDiffRecord: Equatable, Hashable {
    public var added: Int
    public var removed: Int
    public var snippet: String
    public init(added: Int = 0, removed: Int = 0, snippet: String = "") {
        self.added = added; self.removed = removed; self.snippet = snippet
    }
}

public struct SessionFileChange: Identifiable, Hashable {
    public let path: String
    public let displayPath: String
    public let name: String
    public var kind: String
    public var editCount: Int
    public var completed: Bool
    public var addedLines: Int
    public var removedLines: Int
    public var hasExactDiff: Bool
    public var previewSnippet: String
    public var id: String { path }
}

public struct SessionChangeSummary: Equatable {
    public var changes: [SessionFileChange]
    public var totalAdded: Int
    public var totalRemoved: Int
    public var completedCount: Int
    public var totalCount: Int { changes.count }
    public var isEmpty: Bool { changes.isEmpty }
    public var statusText: String {
        if totalCount == 0 { return "暂无文件变更" }
        return "\(completedCount) / \(totalCount) 个文件已修改"
    }
}

public enum RemoteLinks {
    public static func path(_ raw: String, origin: URL, cwd: String) -> String? {
        guard let url = URL(string: raw), url.user == nil, url.password == nil else { return nil }
        if url.isFileURL || url.scheme == "sandbox" {
            guard url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/") else { return nil }
            return url.path
        }
        if let scheme = url.scheme {
            guard scheme == "https", url.host == origin.host, url.port == origin.port else { return nil }
            if url.path == "/api/files/download" || url.path == "/api/files/read" {
                return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
            }
            if url.path.hasPrefix("/api/files/") { return String(url.path.dropFirst("/api/files".count)) }
            return nil
        }
        guard url.host == nil, !url.path.isEmpty, !url.path.contains("\n") else { return nil }
        if url.path.hasPrefix("/") { return url.path }
        guard url.path.contains("/") || !(url.path as NSString).pathExtension.isEmpty else { return nil }
        let target = URL(fileURLWithPath: cwd).appendingPathComponent(url.path).standardizedFileURL.path
        return FileRules.within(target, root: cwd) ? target : nil
    }

    public static func displayPath(_ fullPath: String, cwd: String) -> String {
        let cleanCwd = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if !cleanCwd.isEmpty, fullPath.hasPrefix(cleanCwd + "/") {
            return String(fullPath.dropFirst(cleanCwd.count + 1))
        }
        if let range = fullPath.range(of: "/brain/") {
            let tail = String(fullPath[range.upperBound...])
            let parts = tail.split(separator: "/", maxSplits: 1)
            if parts.count == 2 { return "产物/" + String(parts[1]) }
        }
        return URL(fileURLWithPath: fullPath).lastPathComponent
    }

    public static func messageImages(_ message: ChatMessage, origin: URL, cwd: String) -> [ArtifactReference] {
        var result: [ArtifactReference] = []
        for item in message.attachments ?? [] {
            guard let p = item.path, item.mime != "inode/directory" else { continue }
            let ref = ArtifactReference(path: p, name: item.name, mime: item.mime)
            if ref.image { result.append(ref) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    public static func artifacts(_ message: ChatMessage, origin: URL, cwd: String) -> [ArtifactReference] {
        var result = (message.attachments ?? []).compactMap { item -> ArtifactReference? in
            guard let path = item.path, item.mime != "inode/directory" else { return nil }
            return ArtifactReference(path: path, name: item.name, mime: item.mime)
        }
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#) {
            let text = message.text as NSString
            for match in regex.matches(in: message.text, range: NSRange(location: 0, length: text.length)) {
                let raw = text.substring(with: match.range(at: 2))
                if let path = path(raw, origin: origin, cwd: cwd),
                   !(path as NSString).pathExtension.isEmpty {
                    result.append(ArtifactReference(path: path, name: FileRules.safeName(path), mime: "application/octet-stream"))
                }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    public static func sessionArtifacts(_ messages: [ChatMessage], origin: URL, cwd: String, excluding modifiedPaths: Set<String> = []) -> [ArtifactReference] {
        var items: [ArtifactReference] = []
        for message in messages where message.role == "assistant" {
            for att in message.attachments ?? [] {
                guard let p = att.path, att.mime != "inode/directory", !modifiedPaths.contains(p) else { continue }
                items.append(ArtifactReference(path: p, name: att.name, mime: att.mime))
            }
            if let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^\)\n]+)\)"#) {
                let text = message.text as NSString
                for match in regex.matches(in: message.text, range: NSRange(location: 0, length: text.length)) {
                    let raw = text.substring(with: match.range(at: 2))
                    guard let p = path(raw, origin: origin, cwd: cwd), !modifiedPaths.contains(p) else { continue }
                    let ext = (p as NSString).pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }
                    let isArtifact = p.contains("/.agy-uploads/") || p.contains("/brain/") || ["zip", "dmg", "pkg", "app", "pdf", "png", "jpg", "jpeg", "webp", "gif", "log"].contains(ext)
                    if isArtifact {
                        items.append(ArtifactReference(path: p, name: FileRules.safeName(p), mime: "application/octet-stream"))
                    }
                }
            }
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }

    public static func processSummary(for message: ChatMessage, cwd: String) -> TurnProcessSummary {
        var commandCount = 0
        var writeOps = 0
        var readOps = 0
        var otherCount = 0
        var writtenPaths = Set<String>()
        var readPaths = Set<String>()
        var isRunning = false
        var hasError = false
        var rows: [ToolRowSummary] = []

        for tool in message.tools ?? [] {
            let lower = tool.name.lowercased()
            let stateUpper = tool.state.uppercased()
            let running = stateUpper == "ACTIVE" || stateUpper == "RUNNING" || stateUpper == "PENDING"
            let failed = (tool.isError == true) || stateUpper == "ERROR" || stateUpper == "FAILED"
            if running { isRunning = true }
            if failed { hasError = true }

            let statusLabel = failed ? "失败" : (running ? "进行中" : "完成")
            let fileParam = Self.extractPath(from: tool.parameters)

            if lower.contains("command") || lower == "bash" || lower == "exec" || lower == "shell" {
                commandCount += 1
                let rawCmd = tool.parameters["CommandLine"].string.isEmpty ? tool.parameters["command"].string : tool.parameters["CommandLine"].string
                let cleanCmd = Self.SummarizeCommand(rawCmd)
                let details = [rawCmd.isEmpty ? tool.parameters.pretty : "$ " + rawCmd, tool.output].filter { !$0.isEmpty }.joined(separator: "\n\n")
                rows.append(ToolRowSummary(id: tool.id, action: cleanCmd.action, target: cleanCmd.target, status: statusLabel, icon: "terminal", isError: failed, isRunning: running, details: details))
            } else if Self.isWriteTool(lower) {
                writeOps += 1
                if !fileParam.isEmpty { writtenPaths.insert(fileParam) }
                let action = lower.contains("edit") || lower.contains("replace") ? "修改文件" : "写入文件"
                let target = fileParam.isEmpty ? tool.name : displayPath(fileParam, cwd: cwd)
                let details = [tool.parameters.pretty, tool.output].filter { !$0.isEmpty }.joined(separator: "\n")
                rows.append(ToolRowSummary(id: tool.id, action: action, target: target, status: statusLabel, icon: "square.and.pencil", isError: failed, isRunning: running, details: details))
            } else if Self.isReadTool(lower) {
                readOps += 1
                if !fileParam.isEmpty { readPaths.insert(fileParam) }
                let action = lower.contains("grep") || lower.contains("search") ? "检索代码" : (lower.contains("find") || lower.contains("list") ? "浏览目录" : "读取文件")
                let target = fileParam.isEmpty ? (tool.parameters["Query"].string.isEmpty ? tool.parameters["query"].string : tool.parameters["Query"].string) : displayPath(fileParam, cwd: cwd)
                let details = [fileParam.isEmpty ? tool.parameters.pretty : fileParam, tool.output].filter { !$0.isEmpty }.joined(separator: "\n")
                rows.append(ToolRowSummary(id: tool.id, action: action, target: target.isEmpty ? tool.name : target, status: statusLabel, icon: "doc.text.magnifyingglass", isError: failed, isRunning: running, details: details))
            } else {
                otherCount += 1
                let details = [tool.parameters.pretty, tool.output].filter { !$0.isEmpty }.joined(separator: "\n")
                rows.append(ToolRowSummary(id: tool.id, action: "调用工具", target: tool.name, status: statusLabel, icon: "wrench.and.screwdriver", isError: failed, isRunning: running, details: details))
            }
        }

        let finalTrimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var thinkings: [String] = []
        var stepNotes: [String] = []
        var rounds: [String] = []
        for step in message.steps ?? [] {
            let t = step.thinking?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let note = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                thinkings.append(t)
                rounds.append(t)
            }
            if !note.isEmpty && note != finalTrimmed {
                stepNotes.append(note)
                if note != t { rounds.append(note) }
            }
        }

        let writtenCount = max(writtenPaths.count, writeOps > 0 && writtenPaths.isEmpty ? writeOps : 0)
        let readCount = max(readPaths.count, readOps)
        return TurnProcessSummary(
            commandCount: commandCount,
            writtenFileCount: writtenCount,
            readFileCount: readCount,
            otherToolCount: otherCount,
            stepNotes: stepNotes,
            thinkings: thinkings,
            rounds: rounds,
            toolRows: rows,
            isRunning: isRunning,
            hasError: hasError
        )
    }

    public static func sessionChanges(
        _ messages: [ChatMessage],
        cwd: String,
        externalDiffs: [String: FileDiffRecord] = [:],
        downloadedLineCounts: [String: Int] = [:]
    ) -> SessionChangeSummary {
        var order: [String] = []
        var items: [String: SessionFileChange] = [:]
        var initialReadLines: [String: Int] = [:]

        for message in messages {
            for tool in message.tools ?? [] {
                let lower = tool.name.lowercased()
                let filePath = extractPath(from: tool.parameters)
                guard !filePath.isEmpty else { continue }

                if isReadTool(lower), initialReadLines[filePath] == nil {
                    if let lines = parseLineCount(from: tool.output) {
                        initialReadLines[filePath] = lines
                    }
                    continue
                }

                guard isWriteTool(lower) else { continue }
                let stateUpper = tool.state.uppercased()
                let done = stateUpper == "DONE" || stateUpper == "COMPLETED" || stateUpper.isEmpty
                let isWriteNew = lower.contains("write") || lower.contains("create")
                let directDiff = extractDirectDiff(from: tool.parameters, isWrite: isWriteNew, previousLines: initialReadLines[filePath])

                if var existing = items[filePath] {
                    existing.editCount += 1
                    existing.completed = existing.completed && done
                    if let directDiff {
                        existing.addedLines += directDiff.added
                        existing.removedLines += directDiff.removed
                        existing.hasExactDiff = true
                        if !directDiff.snippet.isEmpty { existing.previewSnippet = directDiff.snippet }
                    }
                    items[filePath] = existing
                } else {
                    order.append(filePath)
                    let kind = (isWriteNew && initialReadLines[filePath] == nil) ? "新增" : "修改"
                    let name = URL(fileURLWithPath: filePath).lastPathComponent
                    items[filePath] = SessionFileChange(
                        path: filePath,
                        displayPath: displayPath(filePath, cwd: cwd),
                        name: name.isEmpty ? filePath : name,
                        kind: kind,
                        editCount: 1,
                        completed: done,
                        addedLines: directDiff?.added ?? 0,
                        removedLines: directDiff?.removed ?? 0,
                        hasExactDiff: directDiff != nil,
                        previewSnippet: directDiff?.snippet ?? ""
                    )
                }
            }
        }

        var changes: [SessionFileChange] = []
        var totalAdded = 0
        var totalRemoved = 0
        var completedCount = 0

        for path in order {
            guard var item = items[path] else { continue }
            if let ext = externalDiffs[path], (ext.added > 0 || ext.removed > 0 || !ext.snippet.isEmpty) {
                item.addedLines = ext.added
                item.removedLines = ext.removed
                item.hasExactDiff = true
                if !ext.snippet.isEmpty { item.previewSnippet = ext.snippet }
            } else if !item.hasExactDiff, let currentLines = downloadedLineCounts[path] {
                if let beforeLines = initialReadLines[path] {
                    let delta = currentLines - beforeLines
                    if delta >= 0 {
                        item.addedLines = max(1, delta)
                        item.removedLines = max(1, item.editCount)
                    } else {
                        item.addedLines = max(1, item.editCount)
                        item.removedLines = -delta + item.editCount
                    }
                } else {
                    item.addedLines = max(1, currentLines)
                    item.removedLines = 0
                }
                item.hasExactDiff = true
            } else if !item.hasExactDiff {
                // Provide conservative minimum indicator until background diff resolves
                item.addedLines = max(1, item.editCount)
                item.removedLines = item.kind == "修改" ? max(1, item.editCount) : 0
            }

            if item.completed { completedCount += 1 }
            totalAdded += item.addedLines
            totalRemoved += item.removedLines
            changes.append(item)
        }

        return SessionChangeSummary(
            changes: changes,
            totalAdded: totalAdded,
            totalRemoved: totalRemoved,
            completedCount: completedCount
        )
    }

    public static func parseTranscriptDiffs(_ data: Data) -> [String: FileDiffRecord] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var records: [String: FileDiffRecord] = [:]
        var fileContents: [String: String] = [:]

        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let calls = obj["tool_calls"] as? [[String: Any]] else { continue }
            for call in calls {
                let name = (call["name"] as? String ?? "").lowercased()
                let args = (call["args"] as? [String: Any]) ?? (call["parameters"] as? [String: Any]) ?? [:]
                let path = (args["Path"] as? String) ?? (args["path"] as? String) ?? (args["TargetFile"] as? String) ?? ""
                guard !path.isEmpty else { continue }

                if name.contains("write") {
                    let content = (args["Content"] as? String) ?? (args["content"] as? String) ?? ""
                    guard !content.isEmpty else { continue }
                    let diff: FileDiffRecord
                    if let previous = fileContents[path] {
                        diff = computeLineDiff(old: previous, new: content)
                    } else {
                        let count = lineCount(content)
                        let preview = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).map { "+ " + $0 }.joined(separator: "\n")
                        diff = FileDiffRecord(added: count, removed: 0, snippet: preview)
                    }
                    fileContents[path] = content
                    var current = records[path] ?? FileDiffRecord()
                    current.added += diff.added
                    current.removed += diff.removed
                    if !diff.snippet.isEmpty { current.snippet = diff.snippet }
                    records[path] = current
                } else if name.contains("edit") || name.contains("replace") {
                    let target = (args["Target"] as? String) ?? (args["target"] as? String) ?? (args["old_string"] as? String) ?? ""
                    let replacement = (args["Replacement"] as? String) ?? (args["replacement"] as? String) ?? (args["new_string"] as? String) ?? ""
                    guard !target.isEmpty || !replacement.isEmpty else { continue }
                    let diff = computeLineDiff(old: target, new: replacement)
                    if let prev = fileContents[path], !target.isEmpty {
                        fileContents[path] = prev.replacingOccurrences(of: target, with: replacement)
                    }
                    var current = records[path] ?? FileDiffRecord()
                    current.added += diff.added
                    current.removed += diff.removed
                    if !diff.snippet.isEmpty { current.snippet = diff.snippet }
                    records[path] = current
                }
            }
        }
        return records
    }

    public static func computeLineDiff(old: String, new: String) -> FileDiffRecord {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (oldLines.count - prefix) && suffix < (newLines.count - prefix) &&
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let removedSlice = oldLines[prefix..<(oldLines.count - suffix)]
        let addedSlice = newLines[prefix..<(newLines.count - suffix)]
        var snippetLines: [String] = []
        for line in removedSlice.prefix(4) { snippetLines.append("- " + line) }
        for line in addedSlice.prefix(6) { snippetLines.append("+ " + line) }
        return FileDiffRecord(
            added: addedSlice.count,
            removed: removedSlice.count,
            snippet: snippetLines.joined(separator: "\n")
        )
    }

    private static func isWriteTool(_ lower: String) -> Bool {
        lower == "write_file" || lower == "edit_file" || lower == "replace_file_content" ||
        lower == "multi_replace_file_content" || lower == "multi_edit" || lower == "create_file" ||
        lower == "apply_patch" || lower == "write_to_file"
    }

    private static func isReadTool(_ lower: String) -> Bool {
        lower == "read_file" || lower == "view_file" || lower == "grep" || lower == "grep_search" ||
        lower == "find" || lower == "find_by_name" || lower == "list_dir" || lower == "search_files"
    }

    private static func extractPath(from params: JSONValue) -> String {
        for key in ["Path", "path", "TargetFile", "file_path", "File", "DirectoryPath"] {
            let v = params[key].string
            if !v.isEmpty { return v }
        }
        return ""
    }

    private static func extractDirectDiff(from params: JSONValue, isWrite: Bool, previousLines: Int?) -> FileDiffRecord? {
        let content = params["Content"].string.isEmpty ? params["content"].string : params["Content"].string
        if isWrite && !content.isEmpty {
            let count = lineCount(content)
            let removed = previousLines ?? 0
            let preview = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "+ " + $0 }.joined(separator: "\n")
            return FileDiffRecord(added: count, removed: removed, snippet: preview)
        }
        let target = params["Target"].string.isEmpty ? (params["target"].string.isEmpty ? params["old_string"].string : params["target"].string) : params["Target"].string
        let replacement = params["Replacement"].string.isEmpty ? (params["replacement"].string.isEmpty ? params["new_string"].string : params["replacement"].string) : params["Replacement"].string
        if !target.isEmpty || !replacement.isEmpty {
            return computeLineDiff(old: target, new: replacement)
        }
        return nil
    }

    private static func parseLineCount(from output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s+lines"#),
              let match = regex.firstMatch(in: output, range: NSRange(location: 0, length: (output as NSString).length)) else { return nil }
        return Int((output as NSString).substring(with: match.range(at: 1)))
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: "\n").count
    }

    private static func SummarizeCommand(_ raw: String) -> (action: String, target: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("运行指令", "终端命令") }
        if trimmed.contains("device_tool.py") {
            if let range = trimmed.range(of: "--command ") {
                let after = String(trimmed[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                return ("Mac 本机执行", String(after.prefix(72)))
            }
            if trimmed.contains(" inspect") {
                return ("探测本机环境", "检查在线 Mac 与工具链")
            }
        }
        let firstLine = trimmed.components(separatedBy: "\n").first ?? trimmed
        return ("运行指令", String(firstLine.prefix(80)))
    }
}
