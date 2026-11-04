import Foundation

public enum MacError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public struct Credentials: Codable, Equatable {
    public let address: URL
    public let token: String
    public init(address: String, token: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/"].contains(url.path), token.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MacError.message("请输入 HTTPS 服务器地址和完整连接密钥。")
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.path = ""; self.address = parts.url!; self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var origin: String { address.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
public struct ModelVariant: Codable, Hashable { public let id: String; public let effort: String }
public struct ModelFamily: Codable, Identifiable, Hashable {
    public let id: String; public let name: String; public let variants: [ModelVariant]; public let efforts: [String]; public let defaultEffort: String
}
public struct ModelInfo: Codable, Identifiable { public let id: String; public let name: String }
public struct ModelReply: Codable { public let models: [ModelInfo]; public let families: [ModelFamily] }
public struct Capabilities: Codable {
    public let separateEffort: Bool; public let nativeApprovals: Bool
    public var aiHybridBuilds: Bool?; public var fileBrowser: Bool?; public var directoryMentions: Bool?; public var projectSnapshots: Bool?
}
public struct GatewayStatus: Codable {
    public let name: String; public let version: Int; public let roots: [String]; public let defaultModel: String; public let accountProfile: String; public let capabilities: Capabilities
}
public struct Attachment: Codable, Identifiable, Hashable {
    public let id: String; public let name: String; public let mime: String; public let size: Int64; public let path: String?
    public var isImage: Bool { mime.hasPrefix("image/") }
}
public struct ToolCall: Codable, Identifiable { public let id: String; public let name: String; public let state: String; public let parameters: JSONValue; public let output: String; public let isError: Bool? }
public struct ResponseStep: Codable { public let index: Int; public let text: String; public let thinking: String? }
public struct ChatMessage: Codable, Identifiable {
    public let id: String; public let role: String; public let text: String; public var attachments: [Attachment]?; public var tools: [ToolCall]?; public var steps: [ResponseStep]?
}
public struct Approval: Codable, Identifiable {
    public let id: String; public let sessionID: String; public let tool: String; public let parameters: JSONValue; public let createdAt: Double; public let expiresAt: Double
}
public struct Session: Codable, Identifiable {
    public let id: String; public var name: String; public let cwd: String; public let model: String; public let mode: String; public let modified: Double; public let running: Bool
    public let conversationID: String; public let error: String; public let revision: Int; public var messages: [ChatMessage]?; public let baseModel: String?; public let effort: String?; public let approvalMode: String?; public var approvals: [Approval]?
    public var title: String { let text = name.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines); return text.isEmpty ? "新对话" : text }
}
public struct SessionReply: Codable { public let sessions: [Session] }
public struct FileEntry: Codable, Identifiable, Hashable {
    public let name: String; public let path: String; public let directory: Bool; public let size: Int64; public let modified: Double
    public var id: String { path }
}
public struct FileListing: Codable { public let root: String; public let path: String; public let entries: [FileEntry] }
public struct LimitReply: Codable { public let fetchedAt: Double; public let source: String; public let groups: [LimitGroup]; public var description: String? }
public struct LimitGroup: Codable, Identifiable { public let name: String; public var description: String?; public let buckets: [LimitBucket]; public var id: String { name } }
public struct LimitBucket: Codable, Identifiable {
    public let id: String; public let name: String; public var remaining_fraction: Double?; public var reset_time: String?; public var window: String?
    public var remaining: Double? { remaining_fraction.map { min(1, max(0, $0)) } }
}
public struct TaskSettings: Codable, Equatable {
    public var model = "", effort = "", approvalMode = "review", mode = "plan", workspace = ""
    public init() {}
    public mutating func validate(_ families: [ModelFamily], roots: [String], defaultModel: String) throws {
        guard let family = families.first(where: { $0.id == model }) ?? families.first(where: { $0.variants.contains { $0.id == defaultModel } }) ?? families.first, let root = roots.first else { throw MacError.message("服务器没有可用模型或工作区。") }
        model = family.id
        if !family.efforts.contains(effort) { effort = family.variants.first(where: { $0.id == defaultModel })?.effort ?? family.defaultEffort }
        if !["review", "turbo"].contains(approvalMode) { approvalMode = "review" }
        if !["plan", "accept-edits"].contains(mode) { mode = "plan" }
        if !roots.contains(where: { FileRules.within(workspace, root: $0) }) { workspace = root }
    }
    public var body: JSONValue { .object(["baseModel": .string(model), "effort": .string(effort), "approvalMode": .string(approvalMode), "mode": .string(mode), "cwd": .string(workspace)]) }
}
public struct FileReference: Codable, Identifiable, Equatable {
    public let path: String; public let label: String; public let directory: Bool
    public var id: String { path }
    public var isImage: Bool { !directory && FileRules.isImage(path) }
    public init(path: String, label: String, directory: Bool) { self.path = path; self.label = label; self.directory = directory }
}
public struct Draft: Codable { public var text = ""; public var references: [FileReference] = []; public init() {} }
public struct PendingSend: Codable {
    public let sessionID: String; public let requestID: String; public let text: String; public let references: [FileReference]
    public init(sessionID: String, requestID: String = UUID().uuidString.lowercased(), draft: Draft) { self.sessionID = sessionID; self.requestID = requestID; text = draft.text; references = draft.references }
    public var body: JSONValue { .object(["text": .string(text), "requestID": .string(requestID), "attachments": .array([]), "references": .array(references.map { .string($0.path) })]) }
}
public struct QueuedMessage: Codable, Identifiable { public let id: String; public let draft: Draft; public init(draft: Draft) { id = UUID().uuidString.lowercased(); self.draft = draft } }
public struct Skill: Codable, Identifiable {
    public let id: String; public var name: String; public var prompt: String; public var path: String?
    public init(name: String, prompt: String, path: String? = nil) { id = UUID().uuidString; self.name = name; self.prompt = prompt; self.path = path }
}
public struct BuildPlan: Codable {
    public let target: String; public let folder: String; public let command: String
    public init(target: String, folder: String, command: String) { self.target = target; self.folder = folder; self.command = command }
}
public struct ProfileState: Codable {
    public var aiBuildsEnabled: Bool?
    public var build: BuildPlan?
    public var settings = TaskSettings(); public var presentation = "步骤摘要"; public var theme = "system"
    public var drafts: [String: Draft] = [:]; public var queues: [String: [QueuedMessage]] = [:]; public var pending: PendingSend?; public var skills: [Skill] = []
    public init() {}
}
public struct NetworkSettings: Codable, Equatable {
    public var encryptedDNS = false; public var provider = "Cloudflare"; public var customDNS = ""; public var proxy = ""
    public init() {}
    public var resolver: URL? { URL(string: customDNS.isEmpty ? ["Cloudflare":"https://cloudflare-dns.com/dns-query", "Google":"https://dns.google/dns-query", "AliDNS":"https://dns.alidns.com/dns-query", "DNSPod":"https://doh.pub/dns-query"][provider] ?? "" : customDNS) }
    public var bootstrap: [String] { customDNS.isEmpty ? ["Cloudflare":["1.1.1.1", "1.0.0.1"],"Google":["8.8.8.8", "8.8.4.4"],"AliDNS":["223.5.5.5", "223.6.6.6"],"DNSPod":["1.12.12.12", "120.53.53.53"]][provider] ?? [] : [] }
    public func validate() throws {
        if encryptedDNS { guard let url = resolver, url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw MacError.message("DoH 地址必须是无登录信息的 HTTPS URL。") } }
        if !proxy.isEmpty && proxy != "direct" { guard let url = URL(string: proxy), ["http", "socks5"].contains(url.scheme ?? ""), url.host != nil, let port = url.port, (1...65535).contains(port), ["", "/"].contains(url.path), url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else { throw MacError.message("代理格式：http://127.0.0.1:7890 或 socks5://127.0.0.1:7891；direct 表示直连。") } }
    }
}
public enum FileRules {
    public static let maxFile: Int64 = 25 * 1024 * 1024
    public static func within(_ path: String, root: String) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
        let base = root == "/" ? "" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root == "/" || path == "/" + base || path.hasPrefix("/" + base + "/")
    }
    public static func label(scope: String, folder: String, name: String, directory: Bool) -> String {
        (scope == "uploads" ? "上传/" : scope == "artifacts" ? "产物/" : "") + [folder, name].filter { !$0.isEmpty }.joined(separator: "/") + (directory ? "/" : "")
    }
    public static func safeName(_ value: String) -> String {
        let base = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "download"
        let name = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).replacingOccurrences(of: ":", with: "_")
        return name.isEmpty || [".", ".."].contains(name) ? "download" : String(name.prefix(180))
    }
    public static func effort(_ value: String) -> String { ["low":"低", "medium":"中", "high":"高", "xhigh":"更高", "max":"最高", "":"默认"][value] ?? value }
    public static func isImage(_ value: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"].contains((value as NSString).pathExtension.lowercased())
    }
}
