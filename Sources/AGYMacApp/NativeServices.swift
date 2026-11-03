#if os(macOS)
import Foundation
import AppKit
import Security
import CryptoKit
import Network
import AGYMacCore

final class Keychain {
    static let service = "com.ddyec.agy-mac"
    static func read(_ account: String) throws -> Data? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MacError.message("钥匙串读取失败（\(status)）。现有连接和待确认任务未删除。") }
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let attributes: [String:Any] = [kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _,new in new } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw MacError.message("钥匙串保存失败（\(status)），没有发送任务。") }
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MacError.message("钥匙串更新失败（\(status)）。") }
    }
    static func storageKey(create: Bool) throws -> SymmetricKey {
        if let data = try read("state-key") { guard data.count == 32 else { throw MacError.message("保存状态的密钥无效，请保留原文件。") }; return SymmetricKey(data:data) }
        guard create else { throw MacError.message("找不到状态解密密钥。请保留 state.bin，不要覆盖待确认发送记录。") }
        let key = SymmetricKey(size:.bits256); let data = key.withUnsafeBytes { Data($0) }; try write(data,account:"state-key"); return key
    }
    static func storage() -> AtomicStateStorage {
        let folder = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AGY-Mac",isDirectory:true)
        return AtomicStateStorage(url:folder.appendingPathComponent("state.bin"), seal:{ data in
            guard let encrypted = try AES.GCM.seal(data,using:storageKey(create:true)).combined else { throw MacError.message("无法加密状态。") }; return encrypted
        },open:{ data in try AES.GCM.open(AES.GCM.SealedBox(combined:data),using:storageKey(create:false)) })
    }
}
@MainActor enum NativeNetwork {
    static func configuration(_ settings: NetworkSettings) throws -> URLSessionConfiguration {
        try settings.validate()
        let resolver: NWParameters.PrivacyContext.ResolverConfiguration? = settings.encryptedDNS ? settings.resolver.map { .https($0,serverAddresses:settings.bootstrap.map { .hostPort(host:NWEndpoint.Host($0),port:.https) }) } : nil
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(settings.encryptedDNS,fallbackResolver:resolver)
        let config = URLSessionConfiguration.ephemeral
        if settings.proxy == "direct" { config.connectionProxyDictionary = [:] }
        else if !settings.proxy.isEmpty, let url = URL(string:settings.proxy), let host = url.host, let port = url.port {
            if url.scheme == "socks5" { config.connectionProxyDictionary = ["SOCKSEnable":1,"SOCKSProxy":host,"SOCKSPort":port,"SOCKSVersion":5] }
            else { config.connectionProxyDictionary = ["HTTPEnable":1,"HTTPProxy":host,"HTTPPort":port,"HTTPSEnable":1,"HTTPSProxy":host,"HTTPSPort":port] }
        }
        return config
    }
}
@MainActor enum NativeFiles {
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel(); panel.title = "上传工作文件"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel(); panel.title = "选择本机项目文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func destination(_ name: String) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = FileRules.safeName(name); panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func save(_ temporary: URL, to target: URL) throws {
        let data = try Data(contentsOf:temporary); guard Int64(data.count) <= FileRules.maxFile else { throw MacError.message("文件超过下载限制。") }
        try data.write(to:target,options:.atomic)
    }
    static func paste(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string) }
}
#endif
