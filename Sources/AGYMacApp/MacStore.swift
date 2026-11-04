#if os(macOS)
import SwiftUI
import AppKit
import AGYMacCore

enum Page: String, CaseIterable, Identifiable {
    case chat, files, builds, skills, settings
    var id: String { rawValue }
    var title: String { switch self { case .chat:return "对话"; case .files:return "文件与产物"; case .builds:return "混合构建"; case .skills:return "技能与工作流"; case .settings:return "配置与额度" } }
    var icon: String { switch self { case .chat:return "bubble.left.and.bubble.right"; case .files:return "folder"; case .builds:return "hammer"; case .skills:return "sparkles"; case .settings:return "slider.horizontal.3" } }
}
private struct UnavailableStorage: StateStorage {
    func load() throws -> AppState { AppState() }
    func save(_ state: AppState) throws { throw MacError.message("保存状态不可用，请先处理钥匙串或 state.bin 的读取错误。") }
}
@MainActor final class MacStore: ObservableObject {
    let captureEnabled = ProcessInfo.processInfo.arguments.contains("--capture-ui")
    @Published var captureTheme: String?
    let localBuild = LocalBuild()
    let hybridWorker = HybridWorker()
    private var buildScope = ""
    let engine: Workspace
    @Published var page = Page.chat
    @Published var busy = false
    @Published var error: String?
    @Published var showTaskOptions = false
    @Published var showReferences = false
    @Published var choosingProject = false
    @Published var previewURL: URL?
    @Published var text = "" { didSet { scheduleDraft() } }
    @Published var limits: LimitReply?
    @Published var images: [String: URL] = [:]
    @Published var sessionDiffs: [String: [String: FileDiffRecord]] = [:]
    @Published var sessionLineCounts: [String: [String: Int]] = [:]
    @Published var turnDurations: [String: Int] = [:]
    private(set) var storageReady = true
    private var restoring = false, restored = false, syncing = false, flushingDraft = false
    private var draftTask: Task<Void,Never>?
    private var draftKey = "", engineText = ""
    private var imageTasks: [String: Task<URL?,Never>] = [:]
    private var diffRevision: [String: Int] = [:]
    private var diffTask: Task<Void,Never>?
    private var selectTask: Task<Void,Never>?
    private var turnStartTimes: [String: Date] = [:]
    var connected: Bool { engine.connected }
    var colorScheme: ColorScheme? { let theme = captureTheme ?? engine.profile.theme; return theme == "dark" ? .dark : theme == "light" ? .light : nil }
    init() {
        CaptureTrace.mark("store.init")
        if ProcessInfo.processInfo.arguments.contains("--capture-ui") || HybridVerification.enabled {
            if let url = Bundle.main.url(forResource:"Mark",withExtension:"png") { VisualFixture.png = (try? Data(contentsOf:url)) ?? Data() }
            engine = try! Workspace(storage:PreviewStorage(),watchEnabled:false,factory:{ credentials,_ in
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VisualFixture.self]; return GatewayClient(credentials:credentials,configuration:config)
            })
        } else {
        do { engine = try Workspace(storage:Keychain.storage(),factory:{ credentials,settings in GatewayClient(credentials:credentials,configuration:try NativeNetwork.configuration(settings)) },saveCredentials:{ value in
            if let value { try Keychain.write(JSONEncoder().encode(value),account:"connection") } else { try Keychain.remove("connection") }
        }) } catch { engine = try! Workspace(storage:UnavailableStorage()); storageReady = false; self.error = "无法读取保存状态：\(error.localizedDescription)。原文件已保留，未覆盖。" }
        }
        engine.beforeSubmit = { [weak self] sid in guard let self else { return }; try await self.hybridWorker.prepare(sid,store:self) }
        engine.changed = { [weak self] in self?.sync() }; CaptureTrace.mark("store.ready")
    }
    func sync() {
        let key = engine.scope + "#" + (engine.selected?.id ?? "new"), incoming = engine.draft.text
        if flushingDraft {
            draftKey = key; engineText = incoming
            return
        }
        objectWillChange.send()
        if !connected || engine.profile.aiBuildsEnabled == false { hybridWorker.stop() }
        if !engine.scope.isEmpty, engine.scope != buildScope, !localBuild.running {
            buildScope = engine.scope; localBuild.reset()
            if let plan = engine.profile.build { localBuild.folder = plan.folder; localBuild.command = plan.command }
        }
        if draftKey != key || text == engineText {
            if text != incoming {
                syncing = true; draftTask?.cancel(); draftTask = nil; text = incoming; syncing = false
            }
        }
        draftKey = key; engineText = incoming
        if let selected = engine.selected {
            trackTurnDuration(for:selected)
            scheduleDiffRefresh(for:selected)
        }
    }
    private func trackTurnDuration(for session: Session) {
        guard let last = session.messages?.last, last.role == "assistant" else { return }
        if session.running {
            if turnStartTimes[last.id] == nil {
                turnStartTimes[last.id] = Date()
            } else if let start = turnStartTimes[last.id] {
                turnDurations[last.id] = max(1, Int(Date().timeIntervalSince(start)))
            }
        } else if let start = turnStartTimes.removeValue(forKey:last.id) {
            turnDurations[last.id] = max(1, Int(Date().timeIntervalSince(start)))
        }
    }
    private func scheduleDraft() {
        guard !syncing, connected else { return }; draftTask?.cancel()
        let key = engine.scope + "#" + (engine.selected?.id ?? "new")
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:400_000_000)
            guard !Task.isCancelled, let self, key == self.engine.scope + "#" + (self.engine.selected?.id ?? "new") else { return }
            do { try self.flushDraft() } catch { self.error = error.localizedDescription }
        }
    }
    func flushDraft() throws {
        draftTask?.cancel(); draftTask = nil
        if connected, text != engine.draft.text {
            flushingDraft = true
            defer { flushingDraft = false }
            try engine.updateDraft(text)
        }
    }
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false; sync() }; do { try flushDraft(); try await operation() } catch { if !(error is CancellationError) { self.error = error.localizedDescription } } }
    }
    func restore() async {
        guard !restored else { return }; restored = true; if captureEnabled || HybridVerification.enabled { return }; guard storageReady else { return }
        do {
            if let data = try Keychain.read("connection") { let value = try JSONDecoder().decode(Credentials.self,from:data); busy = true; defer { busy = false }; try await engine.connect(value); sync() }
        } catch { self.error = error.localizedDescription }
    }
    func connect(address: String, token: String) async throws {
        guard storageReady else { throw MacError.message("保存状态未能读取，请先处理启动错误。") }
        try await engine.connect(Credentials(address:address,token:token)); sync()
    }
    func newConversation() async throws { try flushDraft(); try engine.newConversation(); page = .chat; sync() }
    func reload() async throws { try await engine.reload() }
    func select(_ session: Session) {
        if engine.selected?.id == session.id, page == .chat, engine.selected?.messages != nil { return }
        selectTask?.cancel()
        error = nil
        if page != .chat { page = .chat }
        do { try flushDraft() } catch { self.error = error.localizedDescription; return }
        selectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.engine.select(session.id)
                if let loaded = self.engine.selected, loaded.id == session.id {
                    MessageBlockCache.shared.prewarm(
                        messages: Array((loaded.messages ?? []).suffix(24)),
                        origin: self.engine.client?.credentials.address,
                        cwd: self.engine.settings.workspace
                    )
                }
            } catch {
                if !(error is CancellationError) {
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func send() { run { try await self.engine.send() } }
    func queue() { run { try await self.engine.enqueue() } }
    func steer() { run { try await self.engine.steer() } }
    func insert(_ prompt: String) {
        text = prompt + text
    }
    func upload(_ urls: [URL]? = nil, reference: Bool = true) async throws {
        let files = urls ?? NativeFiles.chooseFiles(); guard files.count <= 8 else { throw MacError.message("每批最多上传 8 个文件。") }
        for url in files {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let item = try await engine.upload(url,reference:reference)
            if let remotePath = item.path, FileRules.isImage(remotePath) || item.isImage {
                cacheLocalPreview(from:url,remotePath:remotePath,name:item.name,sessionID:engine.selected?.id ?? "")
            }
        }
    }
    func pasteClipboardMedia() -> Bool {
        let urls = NativeFiles.clipboardMediaURLs()
        guard !urls.isEmpty else { return false }
        run { try await self.upload(urls,reference:true) }
        return true
    }
    private func cacheLocalPreview(from localURL: URL, remotePath: String, name: String, sessionID: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AGY-Mac-Previews/" + UUID().uuidString,isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let destination = folder.appendingPathComponent(FileRules.safeName(name))
        if (try? FileManager.default.copyItem(at:localURL,to:destination)) != nil {
            images[engine.scope + "##" + remotePath] = destination
            if !sessionID.isEmpty { images[engine.scope + "#" + sessionID + "#" + remotePath] = destination }
        }
    }
    private func scheduleDiffRefresh(for session: Session) {
        guard !captureEnabled, connected else { return }
        guard diffRevision[session.id] != session.revision else { return }
        guard let messages = session.messages, !messages.isEmpty else { return }
        let summary = RemoteLinks.sessionChanges(messages,cwd:engine.settings.workspace,externalDiffs:sessionDiffs[session.id] ?? [:],downloadedLineCounts:sessionLineCounts[session.id] ?? [:])
        guard !summary.isEmpty else {
            diffRevision[session.id] = session.revision
            return
        }
        diffRevision[session.id] = session.revision
        diffTask?.cancel()
        let sid = session.id, scopeSnapshot = engine.scope
        let missingChanges = summary.changes.filter { sessionDiffs[sid]?[$0.path] == nil && sessionLineCounts[sid]?[$0.path] == nil }
        diffTask = Task { [weak self] in
            // Wait until session transition & initial scroll settle before doing background network/disk diff work
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.engine.scope == scopeSnapshot else { return }

            var updatedDiffs = self.sessionDiffs[sid] ?? [:]
            var updatedLineCounts = self.sessionLineCounts[sid] ?? [:]
            var didChange = false

            if let listing = try? await self.engine.browse(scope:"artifacts",path:""), !listing.root.isEmpty {
                for candidate in ["/.system_generated/logs/transcript_full.jsonl", "/.system_generated/logs/transcript.jsonl"] {
                    guard !Task.isCancelled else { return }
                    if let temp = try? await self.engine.download(listing.root + candidate,sessionID:sid) {
                        let parsed = await Task.detached(priority: .utility) { () -> [String: FileDiffRecord] in
                            defer { try? FileManager.default.removeItem(at: temp) }
                            guard let data = try? Data(contentsOf: temp) else { return [:] }
                            return RemoteLinks.parseTranscriptDiffs(data)
                        }.value
                        if !parsed.isEmpty {
                            updatedDiffs = parsed
                            didChange = true
                            break
                        }
                    }
                }
            }

            for change in missingChanges where updatedDiffs[change.path] == nil && updatedLineCounts[change.path] == nil {
                guard !Task.isCancelled, self.engine.scope == scopeSnapshot else { return }
                if let temp = try? await self.engine.download(change.path,sessionID:sid) {
                    let result = await Task.detached(priority: .utility) { () -> (Int, String)? in
                        defer { try? FileManager.default.removeItem(at: temp) }
                        guard let text = try? String(contentsOf: temp, encoding: .utf8) else { return nil }
                        let count = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
                        let preview = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "+ " + $0 }.joined(separator: "\n")
                        return (count, preview)
                    }.value
                    if let (count, preview) = result {
                        updatedLineCounts[change.path] = count
                        if change.previewSnippet.isEmpty {
                            updatedDiffs[change.path] = FileDiffRecord(added: 0, removed: 0, snippet: preview)
                        }
                        didChange = true
                    }
                }
            }

            guard !Task.isCancelled, self.engine.scope == scopeSnapshot, didChange else { return }
            self.sessionLineCounts[sid] = updatedLineCounts
            self.sessionDiffs[sid] = updatedDiffs
        }
    }
    func download(_ artifact: ArtifactReference, sessionID: String? = nil) async throws {
        guard let target = NativeFiles.destination(artifact.name) else { return }
        let temporary = try await engine.download(artifact.path,sessionID:sessionID); defer { try? FileManager.default.removeItem(at:temporary) }
        try NativeFiles.save(temporary,to:target); NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    func image(_ artifact: ArtifactReference, sessionID: String) async -> URL? {
        let key = engine.scope + "#" + sessionID + "#" + artifact.path
        if let value = images[key] ?? images[engine.scope + "##" + artifact.path] { return value }
        if let task = imageTasks[key] { return await task.value }
        let oldScope = engine.scope
        let task = Task<URL?,Never> {
            do {
                let temporary = try await engine.download(artifact.path,sessionID:sessionID)
                guard engine.scope == oldScope else { try? FileManager.default.removeItem(at:temporary); return nil }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AGY-Mac-Previews/" + UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let destination = folder.appendingPathComponent(FileRules.safeName(artifact.name)); try FileManager.default.moveItem(at:temporary,to:destination)
                images[key] = destination; return destination
            } catch { return nil }
        }
        imageTasks[key] = task; let value = await task.value; imageTasks.removeValue(forKey:key); return value
    }
    func open(_ url: URL) -> OpenURLAction.Result {
        if let origin = engine.client?.credentials.address, let remote = RemoteLinks.path(url.absoluteString,origin:origin,cwd:engine.settings.workspace) {
            run { try await self.download(ArtifactReference(path:remote,name:FileRules.safeName(remote),mime:"application/octet-stream")) }; return .handled
        }
        if url.scheme == "https", url.user == nil, url.password == nil { NSWorkspace.shared.open(url); return .handled }
        return .discarded
    }
    func chooseProject() { choosingProject = true; showReferences = true }
    func mention() { choosingProject = false; showReferences = true }
    func preferences(theme: String? = nil, presentation: String? = nil) {
        do { try engine.preferences(theme:theme,presentation:presentation); sync() } catch { self.error = error.localizedDescription }
    }
    func applyNetwork(_ value: NetworkSettings) async throws {
        let connection = engine.client?.credentials; try engine.setNetwork(value)
        if let connection { try await engine.connect(connection) }
    }
    func disconnect() async throws { guard !localBuild.running else { throw MacError.message("请先停止本机构建，再切换连接。") }; try engine.disconnect(); page = .chat; sync() }
}
#endif
