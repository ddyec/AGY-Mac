import Foundation

public enum JSONValue: Codable, Hashable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let fields) = self { return fields[key] ?? .null }; return .null }
    public var string: String { if case .string(let value) = self { return value }; return "" }
    public var array: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    public var pretty: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]; return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "" }
}
public struct SSEFramer {
    private var line: [UInt8] = [], lines: [String] = []
    private var bytes = 0, previousCR = false, firstLine = true
    public init() {}
    public mutating func consume(_ byte: UInt8) throws -> String? {
        if previousCR { previousCR = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            previousCR = byte == 13
            var current = line; line.removeAll(keepingCapacity: true)
            if firstLine { firstLine = false; if current.starts(with: [239,187,191]) { current.removeFirst(3) } }
            let text = String(decoding: current, as: UTF8.self)
            if text.isEmpty { defer { lines.removeAll(keepingCapacity: true); bytes = 0 }; return lines.isEmpty ? nil : lines.joined(separator: "\n") }
            if text.hasPrefix("data:") {
                var data = String(text.dropFirst(5)); if data.first == " " { data.removeFirst() }
                bytes += data.utf8.count
                guard bytes <= 20 * 1024 * 1024 else { throw MacError.message("事件内容过大。") }
                lines.append(data)
            }
            return nil
        }
        guard line.count < 20 * 1024 * 1024 else { throw MacError.message("事件内容过大。") }
        line.append(byte); return nil
    }
}
public struct AppState: Codable {
    public var network = NetworkSettings(); public var profiles: [String: ProfileState] = [:]
    public init() {}
    public static func scope(origin: String, account: String) -> String { origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "#" + account }
}
public protocol StateStorage {
    func load() throws -> AppState
    func save(_ state: AppState) throws
}
public final class AtomicStateStorage: StateStorage {
    private let url: URL; private let seal: (Data) throws -> Data; private let open: (Data) throws -> Data
    public init(url: URL, seal: @escaping (Data) throws -> Data, open: @escaping (Data) throws -> Data) { self.url = url; self.seal = seal; self.open = open }
    public func load() throws -> AppState {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppState() }
        return try JSONDecoder().decode(AppState.self, from: open(Data(contentsOf: url)))
    }
    public func save(_ state: AppState) throws {
        let data = try seal(JSONEncoder().encode(state))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
public enum MessageParts {
    public struct Block: Identifiable { public var id: Int; public var text: String; public var language: String? }
    public static func blocks(_ text: String) -> [Block] {
        text.components(separatedBy: "```").enumerated().map { index, part in
            guard index % 2 == 1 else { return Block(id: index, text: part, language: nil) }
            let pieces = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return Block(id: index, text: pieces.count > 1 ? String(pieces[1]) : part, language: pieces.count > 1 ? String(pieces[0]) : "code")
        }.filter { !$0.text.isEmpty }
    }
}
