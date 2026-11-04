import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GatewayError: LocalizedError {
    public let status: Int; public let message: String
    public var errorDescription: String? { message }
}
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class GatewayClient {
    public let credentials: Credentials
    private let session: URLSession
    private let policy = RedirectPolicy()
    public init(credentials: Credentials, configuration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        configuration.timeoutIntervalForRequest = 65; configuration.timeoutIntervalForResource = 600
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func invalidate() { session.invalidateAndCancel() }
    public func request(_ path: String, query: [String:String] = [:], method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        guard !path.contains(".."), !path.contains(":"), !path.contains("\\"), !path.contains("?"), !path.contains("#"), !path.hasPrefix("/") else { throw MacError.message("无效接口路径。") }
        var components = URLComponents(url: credentials.address, resolvingAgainstBaseURL: false)!
        components.path = "/v1/" + path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw MacError.message("无效服务器地址。") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 AGY-Mac/1.0.0", forHTTPHeaderField: "User-Agent")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    public func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let response = response as? HTTPURLResponse else { throw MacError.message("服务器响应无效。") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?["error"].string ?? ""
            let fallback = response.statusCode == 401 ? "连接密钥无效，请重新连接。" : response.statusCode == 502 ? "服务器网关暂不可用（502），请检查后台服务与隧道。" : "服务器返回 HTTP \(response.statusCode)。"
            throw GatewayError(status: response.statusCode, message: detail.isEmpty ? fallback : detail)
        }
    }
    public func json<T: Decodable>(_ path: String, query: [String:String] = [:], method: String = "GET", body: JSONValue? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(path, query: query, method: method, body: body))
        try validate(response, data: data)
        guard data.count <= 32 * 1024 * 1024 else { throw MacError.message("服务器响应过大。") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public static func id(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value) else { throw MacError.message("无效会话或操作编号。") }
        return id.uuidString.lowercased()
    }
    public func upload(_ file: URL, sessionID: String) async throws -> Attachment {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber, size.int64Value <= FileRules.maxFile else { throw MacError.message("请上传普通文件，单个文件上限 25 MB。") }
        var req = try request("sessions/\(try Self.id(sessionID))/attachments", query: ["name":file.lastPathComponent], method: "POST")
        let ext = file.pathExtension.lowercased()
        req.setValue(["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "webp":"image/webp", "gif":"image/gif", "pdf":"application/pdf", "txt":"text/plain", "md":"text/markdown", "zip":"application/zip"][ext] ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (data, response) = try await session.upload(for: req, fromFile: file); try validate(response, data: data)
        return try JSONDecoder().decode(Attachment.self, from: data)
    }
    public func download(_ remote: String, sessionID: String, snapshot: Bool = false, buildID: String? = nil, lease: String? = nil) async throws -> URL {
        var query = ["path":remote]
        if let buildID, let lease { query["build"] = try Self.id(buildID); query["lease"] = lease }
        var req = try request("sessions/\(try Self.id(sessionID))/\(snapshot ? "snapshot" : "files")", query:query)
        req.setValue("*/*", forHTTPHeaderField: "Accept"); req.setValue("identity", forHTTPHeaderField:"Accept-Encoding")
        let (temporary, response) = try await session.download(for: req)
        do {
            try validate(response)
            let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= FileRules.maxFile else { throw MacError.message("下载文件超过 25 MB。") }
            if response.expectedContentLength >= 0 && response.expectedContentLength != size { throw MacError.message("下载未完成，请重试；原有文件未修改。") }
            return temporary
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    public func snapshots(_ sessionID: String, receive: @escaping (Session) async throws -> Void) async throws {
        #if os(macOS)
        var req = try request("sessions/\(try Self.id(sessionID))/events"); req.setValue("text/event-stream", forHTTPHeaderField: "Accept"); req.timeoutInterval = 40
        let (bytes, response) = try await session.bytes(for: req); try validate(response)
        guard response.mimeType == "text/event-stream" else { throw MacError.message("服务器没有返回事件流。") }
        var framer = SSEFramer()
        for try await byte in bytes { try Task.checkCancellation(); if let event = try framer.consume(byte) { try await receive(JSONDecoder().decode(Session.self, from: Data(event.utf8))) } }
        #else
        let value: Session = try await json("sessions/\(try Self.id(sessionID))"); try await receive(value)
        #endif
    }
}
