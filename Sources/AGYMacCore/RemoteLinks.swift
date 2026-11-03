import Foundation
public struct ArtifactReference: Identifiable, Hashable {
    public let path: String; public let name: String; public let mime: String
    public var id: String { path }
    public init(path: String, name: String, mime: String) { self.path = path; self.name = name; self.mime = mime }
    public var image: Bool { mime.hasPrefix("image/") || ["png","jpg","jpeg","webp","gif"].contains((name as NSString).pathExtension.lowercased()) }
}
public enum RemoteLinks {
    public static func path(_ raw: String, origin: URL, cwd: String) -> String? {
        guard let url = URL(string:raw), url.user == nil, url.password == nil else { return nil }
        if url.isFileURL || url.scheme == "sandbox" { guard url.host == nil || url.host == "" || url.host == "localhost", url.path.hasPrefix("/") else { return nil }; return url.path }
        if let scheme = url.scheme {
            guard scheme == "https", url.host == origin.host, url.port == origin.port else { return nil }
            if url.path == "/api/files/download" || url.path == "/api/files/read" { return URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "path" }?.value }
            if url.path.hasPrefix("/api/files/") { return String(url.path.dropFirst("/api/files".count)) }
            return nil
        }
        guard url.host == nil, !url.path.isEmpty, !url.path.contains("\n") else { return nil }
        if url.path.hasPrefix("/") { return url.path }
        guard url.path.contains("/") || !(url.path as NSString).pathExtension.isEmpty else { return nil }
        let target = URL(fileURLWithPath:cwd).appendingPathComponent(url.path).standardizedFileURL.path
        return FileRules.within(target,root:cwd) ? target : nil
    }
    public static func artifacts(_ message: ChatMessage, origin: URL, cwd: String) -> [ArtifactReference] {
        var result = (message.attachments ?? []).compactMap { item -> ArtifactReference? in guard let path = item.path, item.mime != "inode/directory" else { return nil }; return ArtifactReference(path:path,name:item.name,mime:item.mime) }
        if let regex = try? NSRegularExpression(pattern:#"\[([^\]\n]+)\]\(([^\)\n]+)\)"#) {
            let text = message.text as NSString
            for match in regex.matches(in:message.text,range:NSRange(location:0,length:text.length)) {
                let raw = text.substring(with:match.range(at:2))
                if let path = path(raw,origin:origin,cwd:cwd) { result.append(ArtifactReference(path:path,name:FileRules.safeName(path),mime:"application/octet-stream")) }
            }
        }
        var seen = Set<String>(); return result.filter { seen.insert($0.path).inserted }
    }
}
