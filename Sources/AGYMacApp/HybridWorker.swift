#if os(macOS)
import Foundation
import SwiftUI
import AGYMacCore

private struct DeviceAck: Decodable { let accountProfile: String }
private struct BuildJob: Decodable { let id: String; let sessionID: String; let command: String; let subdirectory: String; let artifacts: [String]; let deadline: Double }
private struct BuildDispatch: Decodable { let job: BuildJob?; let lease: String?; let accountProfile: String }

@MainActor final class HybridWorker: ObservableObject {
    @Published var status = "连接后自动探测编译环境"
    @Published var tools: [String] = []
    @Published var executing = false
    private var task: Task<Void,Never>?
    private var client: GatewayClient?
    private var scope = "", account = "", device = UUID().uuidString.lowercased()
    private var sessions = Set<String>()
    private var local: LocalBuild?
    private var leaseLost = false
    private var detected = false
    deinit { task?.cancel() }
    func preview() {
        guard ProcessInfo.processInfo.arguments.contains("--capture-ui") else { return }
        status = "AI 自动构建就绪 · 离线示例"; tools = ["swift","xcodebuild","clang","node"]
    }
    func stop() {
        task?.cancel(); task = nil
        if executing { local?.stop() }
        client = nil; sessions.removeAll(); scope = ""; device = UUID().uuidString.lowercased(); status = "AI 本机构建已暂停"
    }
    func prepare(_ sid: String, store: MacStore) async throws {
        guard !store.captureEnabled, store.engine.profile.aiBuildsEnabled != false else { return }
        guard store.engine.status?.capabilities.aiHybridBuilds == true else { status = "服务器需要升级 AI 构建接口"; return }
        guard let api = store.engine.client, let profile = store.engine.status?.accountProfile else { return }
        if scope != store.engine.scope { stop(); scope = store.engine.scope; account = profile; client = api; local = store.localBuild }
        if !detected {
            status = "正在探测 Intel Mac 编译工具…"
            tools = await Self.detect(); detected = true
        }
        try await register(sid,api:api); sessions.insert(sid)
        if task == nil {
            status = "AI 自动构建已就绪 · Intel Mac"
            task = Task { [weak self] in await self?.loop() }
        }
    }
    private func register(_ sid: String, api: GatewayClient) async throws {
        let body: JSONValue = .object(["deviceID":.string(device),"platform":.string("macos"),"architecture":.string("x86_64"),"tools":.array(tools.map { .string($0) })])
        let ack: DeviceAck = try await api.json("sessions/\(try GatewayClient.id(sid))/device",method:"POST",body:body)
        guard ack.accountProfile == account else { throw MacError.message("服务器账号已变化，已停止本机构建。") }
    }
    private func loop() async {
        while !Task.isCancelled {
            guard let api = client else { return }
            do {
                for sid in sessions { try await register(sid,api:api) }
                let reply: BuildDispatch = try await api.json("devices/\(device)/poll",method:"POST",body:.object([:]))
                guard reply.accountProfile == account else { stop(); return }
                if let job = reply.job, let lease = reply.lease { await execute(job,lease:lease,api:api) }
                else { status = "AI 自动构建已就绪 · Intel Mac" }
            } catch {
                if Task.isCancelled { return }
                status = "等待重新连接：" + error.localizedDescription
            }
            try? await Task.sleep(nanoseconds:2_000_000_000)
        }
    }
    private func pulse(_ id: String, lease: String, api: GatewayClient, result: JSONValue? = nil) async throws {
        var body: [String:JSONValue] = ["lease":.string(lease)]
        if let result { body["complete"] = .bool(true); body["result"] = result }
        let ack: DeviceAck = try await api.json("builds/\(try GatewayClient.id(id))",method:"POST",body:.object(body))
        guard ack.accountProfile == account else { throw MacError.message("服务器账号已变化。") }
    }
    private func execute(_ job: BuildJob, lease: String, api: GatewayClient) async {
        guard let local else { return }; executing = true; leaseLost = false
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.pulse(job.id,lease:lease,api:api) }
                catch { self?.leaseLost = true; local.stop(); return }
                try? await Task.sleep(nanoseconds:2_000_000_000)
            }
        }
        defer { heartbeat.cancel(); executing = false }
        do {
            guard !local.running else { throw MacError.message("本机命令正在运行，未重复执行。") }
            status = "AI 正在同步项目…"; HybridVerification.trace("snapshot begin")
            let snapshot = try await api.download(job.subdirectory,sessionID:job.sessionID,snapshot:true,buildID:job.id,lease:lease)
            defer { try? FileManager.default.removeItem(at:snapshot) }
            let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AGY-Mac/Workspaces/AI-"+job.id,isDirectory:true)
            let bytes = try Data(contentsOf:snapshot)
            try await Task.detached { try SnapshotArchive.extract(bytes,to:base) }.value
            guard !Task.isCancelled, !leaseLost, Date().timeIntervalSince1970 < job.deadline else { throw CancellationError() }
            HybridVerification.trace("snapshot extracted"); let cwd = base
            local.folder = cwd.path; local.command = job.command; status = "AI 正在 Intel Mac 上构建…"
            try local.start(); HybridVerification.trace("process started")
            while local.running {
                if Task.isCancelled || leaseLost || Date().timeIntervalSince1970 >= job.deadline { local.stop() }
                try? await Task.sleep(nanoseconds:200_000_000)
            }
            guard !Task.isCancelled, !leaseLost else { throw CancellationError() }
            status = "正在自动回传构建日志与产物…"; HybridVerification.trace("process exited: \(local.exitCode ?? -1)")
            var attachments: [Attachment] = []
            if let logURL = local.outputLogURL { attachments.append(try await api.upload(logURL,sessionID:job.sessionID)) }
            var errors: [String] = []
            for name in job.artifacts {
                do {
                    let path = try Self.confined(name,root:base)
                    try Self.checkLinks(path,root:base)
                    var upload = path
                    if (try path.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true {
                        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"-"+path.lastPathComponent+".zip")
                        try await Self.archive(path,to:out); upload = out
                    }
                    defer { if upload != path { try? FileManager.default.removeItem(at:upload) } }
                    attachments.append(try await api.upload(upload,sessionID:job.sessionID))
                } catch { errors.append(name+": "+error.localizedDescription) }
            }
            let result: JSONValue = .object(["exitCode":.number(Double(local.exitCode ?? -1)),"log":.string(String(local.log.suffix(12000))),"attachments":.array(attachments.map { .string($0.id) }),"artifactPaths":.array(attachments.compactMap { $0.path }.map { .string($0) }),"artifactErrors":.array(errors.map { .string($0) })])
            HybridVerification.trace("upload complete"); try await pulse(job.id,lease:lease,api:api,result:result)
            status = "AI 构建结果已回传 · 退出码 \(local.exitCode ?? -1)"
        } catch {
            HybridVerification.trace("execution failed: "+error.localizedDescription); local.stop()
            if !leaseLost, !Task.isCancelled {
                try? await pulse(job.id,lease:lease,api:api,result:.object(["error":.string(error.localizedDescription),"exitCode":.number(-1),"attachments":.array([])]))
            }
            status = "本次构建已停止："+error.localizedDescription+"；未自动重试"
        }
        // Keep the fresh copy for inspection; never overwrite a user's original project.
    }
    private static func confined(_ relative: String, root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("\\"), !relative.split(separator:"/").contains("..") else { throw MacError.message("构建路径必须位于项目副本内。") }
        let path = root.appendingPathComponent(relative).standardizedFileURL
        let resolved = path.resolvingSymlinksInPath(), base = root.resolvingSymlinksInPath()
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path+"/") else { throw MacError.message("构建产物越过项目边界。") }
        return path
    }
    private static func checkLinks(_ path: URL, root: URL) throws {
        let base = root.resolvingSymlinksInPath().path
        let urls = [path] + ((FileManager.default.enumerator(at:path,includingPropertiesForKeys:[.isSymbolicLinkKey]))?.allObjects as? [URL] ?? [])
        for url in urls { let p = url.resolvingSymlinksInPath().path; guard p == base || p.hasPrefix(base+"/") else { throw MacError.message("产物包含越界符号链接。") } }
    }
    private static func archive(_ source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/ditto"); p.arguments = ["-c","-k","--keepParent",source.path,destination.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { p in if p.terminationStatus == 0 { continuation.resume() } else { continuation.resume(throwing:MacError.message("产物打包失败。")) } }
            do { try p.run() } catch { continuation.resume(throwing:error) }
        }
    }
    private static func detect() async -> [String] {
        await Task.detached {
            let candidates = ["swift","xcodebuild","clang","cmake","node","npm","dotnet","cargo","python3","make"]
            return candidates.filter { name in
                let p = Process(); p.executableURL = URL(fileURLWithPath:"/bin/zsh"); p.arguments = ["-lc","command -v "+name+" >/dev/null 2>&1"]
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            }
        }.value
    }
}
#endif
