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
    private(set) var storageReady = true
    private var restoring = false, restored = false, syncing = false
    private var draftTask: Task<Void,Never>?
    private var draftKey = "", engineText = ""
    private var imageTasks: [String: Task<URL?,Never>] = [:]
    var connected: Bool { engine.connected }
    var colorScheme: ColorScheme? { let theme = captureTheme ?? engine.profile.theme; return theme == "dark" ? .dark : theme == "light" ? .light : nil }
    init() {
        CaptureTrace.mark("store.init")
        if captureEnabled || HybridVerification.enabled {
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
        objectWillChange.send()
        if !connected || engine.profile.aiBuildsEnabled == false { hybridWorker.stop() }
        if !engine.scope.isEmpty, engine.scope != buildScope, !localBuild.running {
            buildScope = engine.scope; localBuild.reset()
            if let plan = engine.profile.build { localBuild.folder = plan.folder; localBuild.command = plan.command }
        }
        let key = engine.scope + "#" + (engine.selected?.id ?? "new"), incoming = engine.draft.text
        if draftKey != key || text == engineText {
            syncing = true; draftTask?.cancel(); draftTask = nil; text = incoming; syncing = false
        }
        draftKey = key; engineText = incoming
    }
    private func scheduleDraft() {
        guard !syncing, connected else { return }; draftTask?.cancel()
        let key = engine.scope + "#" + (engine.selected?.id ?? "new")
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:250_000_000)
            guard !Task.isCancelled, let self, key == self.engine.scope + "#" + (self.engine.selected?.id ?? "new") else { return }
            do { try self.flushDraft() } catch { self.error = error.localizedDescription }
        }
    }
    func flushDraft() throws {
        draftTask?.cancel(); draftTask = nil
        if connected, text != engine.draft.text { try engine.updateDraft(text) }
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
    func select(_ session: Session) { run { try await self.engine.select(session.id); self.page = .chat } }
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
            try await engine.upload(url,reference:reference)
        }
    }
    func download(_ artifact: ArtifactReference, sessionID: String? = nil) async throws {
        guard let target = NativeFiles.destination(artifact.name) else { return }
        let temporary = try await engine.download(artifact.path,sessionID:sessionID); defer { try? FileManager.default.removeItem(at:temporary) }
        try NativeFiles.save(temporary,to:target); NSWorkspace.shared.activateFileViewerSelecting([target])
    }
    func image(_ artifact: ArtifactReference, sessionID: String) async -> URL? {
        let key = engine.scope + "#" + sessionID + "#" + artifact.path
        if let value = images[key] { return value }
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
