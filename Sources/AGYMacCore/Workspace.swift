import Foundation

@MainActor public final class Workspace {
    public var changed: (() -> Void)?
    public private(set) var state: AppState
    public private(set) var connected = false
    public private(set) var status: GatewayStatus?
    public private(set) var families: [ModelFamily] = []
    public private(set) var sessions: [Session] = []
    public private(set) var selected: Session?
    public private(set) var settings = TaskSettings()
    public private(set) var connectionLabel = "尚未连接"
    public private(set) var streamError: String?
    public private(set) var scope = ""
    public private(set) var client: GatewayClient?
    private let watchEnabled: Bool
    private let storage: StateStorage
    private let factory: (Credentials, NetworkSettings) throws -> GatewayClient
    private let saveCredentials: (Credentials?) throws -> Void
    private var watch: Task<Void,Never>?
    private var epoch = UUID(), selectionEpoch = UUID(), draining = false
    private var sessionCache: [String: Session] = [:]
    public init(storage: StateStorage, watchEnabled: Bool = true, factory: @escaping (Credentials,NetworkSettings) throws -> GatewayClient = { c,_ in GatewayClient(credentials:c) }, saveCredentials: @escaping (Credentials?) throws -> Void = { _ in }) throws {
        self.watchEnabled = watchEnabled; self.storage = storage; self.factory = factory; self.saveCredentials = saveCredentials; state = try storage.load()
    }
    public var profile: ProfileState { state.profiles[scope] ?? ProfileState() }
    public var draft: Draft { profile.drafts[selected?.id ?? "new"] ?? Draft() }
    public var pending: PendingSend? { profile.pending }
    public var queue: [QueuedMessage] { profile.queues[selected?.id ?? "new"] ?? [] }
    private func notify() { changed?() }
    private func commit(_ profile: ProfileState, announce: Bool = true) throws {
        guard !scope.isEmpty else { throw MacError.message("请先连接。") }
        var next = state; next.profiles[scope] = profile; try storage.save(next); state = next; if announce { notify() }
    }
    public func setNetwork(_ network: NetworkSettings) throws { try network.validate(); var next = state; next.network = network; try storage.save(next); state = next; notify() }
    public func preferences(theme: String? = nil, presentation: String? = nil) throws {
        var p = profile
        if let theme, ["system","light","dark"].contains(theme) { p.theme = theme }
        if let presentation, ["原版","步骤摘要","结论优先"].contains(presentation) { p.presentation = presentation }
        try commit(p)
    }
    public func connect(_ credentials: Credentials) async throws {
        let token = UUID(); epoch = token; selectionEpoch = UUID(); watch?.cancel(); client?.invalidate(); client = nil; connected = false; selected = nil; sessions = []; sessionCache = [:]; notify()
        let candidate = try factory(credentials,state.network)
        do {
            let status: GatewayStatus = try await candidate.json("status")
            let models: ModelReply = try await candidate.json("models")
            guard token == epoch else { candidate.invalidate(); return }
            guard status.version == 1, !status.roots.isEmpty, !models.families.isEmpty, status.capabilities.separateEffort, status.capabilities.nativeApprovals else { throw MacError.message("请使用支持模型/强度分离及审批控制的新版 AGY 网关。") }
            scope = AppState.scope(origin:credentials.origin,account:status.accountProfile)
            var p = profile; try p.settings.validate(models.families,roots:status.roots,defaultModel:status.defaultModel)
            var next = state; next.profiles[scope] = p; try storage.save(next); try saveCredentials(credentials); state = next
            self.status = status; families = models.families; settings = p.settings; client = candidate; connected = true; connectionLabel = "已连接"; streamError = nil
            try await reload()
            if let pending { try await select(pending.sessionID) }
            notify()
        } catch { candidate.invalidate(); if token == epoch { client = nil; connected = false; connectionLabel = "连接未完成"; notify() }; throw error }
    }
    public func disconnect() throws {
        try saveCredentials(nil); watch?.cancel(); client?.invalidate(); client = nil; connected = false; selected = nil; sessions = []; sessionCache = [:]; epoch = UUID(); scope = ""; connectionLabel = "尚未连接"; notify()
    }
    private func api() throws -> GatewayClient { guard let client, connected else { throw MacError.message("请先连接服务器。") }; return client }
    private func verify() async throws {
        let expected = scope, client = try api(); let status: GatewayStatus = try await client.json("status")
        guard scope == expected, status.accountProfile == self.status?.accountProfile else {
            watch?.cancel(); self.client?.invalidate(); self.client = nil; connected = false; selected = nil; sessions = []; epoch = UUID(); connectionLabel = "账号已变化，请重新连接"; notify()
            throw MacError.message("服务器账号已变化，请重新连接。没有向新账号发送本次操作。")
        }
    }
    public func reload() async throws {
        let key = scope, token = epoch; let response: SessionReply = try await api().json("sessions")
        guard scope == key, epoch == token else { return }; sessions = response.sessions.sorted { $0.modified > $1.modified }; notify()
    }
    public func updateDraft(_ text: String, references: [FileReference]? = nil) throws {
        var p = profile, next = draft; next.text = text; if let references { next.references = references }
        p.drafts[selected?.id ?? "new"] = next; try commit(p)
    }
    public func addReference(_ reference: FileReference) throws {
        guard pending == nil else { throw MacError.message("请先核对待确认发送。") }
        guard !draft.references.contains(where: { $0.path == reference.path }) else { return }
        guard draft.references.count < 8 else { throw MacError.message("每条消息最多引用 8 项；文件夹可以整体引用。") }
        var text = draft.text; if text.hasSuffix("@") { text.removeLast() }
        try updateDraft(text,references:draft.references + [reference])
    }
    public func removeReference(_ path: String) throws { try updateDraft(draft.text,references:draft.references.filter { $0.path != path }) }
    public func newConversation() throws {
        guard pending == nil else { throw MacError.message("请先核对待确认发送；它不会被自动重发。") }
        guard let status else { throw MacError.message("请先连接。") }
        selectionEpoch = UUID(); watch?.cancel(); selected = nil; settings = profile.settings; try settings.validate(families,roots:status.roots,defaultModel:status.defaultModel); streamError = nil; notify()
    }
    private func settingsFor(_ session: Session) -> TaskSettings {
        var result = TaskSettings(); let family = families.first { $0.variants.contains { $0.id == session.model } }
        result.model = family?.id ?? session.baseModel ?? session.model; result.effort = family?.variants.first { $0.id == session.model }?.effort ?? session.effort ?? ""
        result.approvalMode = session.approvalMode ?? "review"; result.mode = session.mode; result.workspace = session.cwd; return result
    }
    public func select(_ id: String) async throws {
        if let pending, pending.sessionID != id { throw MacError.message("请先核对待确认发送，再切换会话。") }
        let token = UUID(), key = scope; selectionEpoch = token; watch?.cancel()
        if let cached = sessionCache[id] { selected = cached; settings = settingsFor(cached); notify() }
        let value: Session = try await api().json("sessions/\(try GatewayClient.id(id))")
        guard key == scope, token == selectionEpoch else { return }
        selected = value; settings = settingsFor(value); sessionCache[id] = value; try reconcile(value); notify(); startWatch(id)
    }
    public func configure(_ requested: TaskSettings) async throws {
        guard pending == nil, selected?.running != true, let status else { throw MacError.message("请先结束当前任务或核对待确认发送。") }
        guard let family = families.first(where: { $0.id == requested.model }), family.efforts.contains(requested.effort), ["review","turbo"].contains(requested.approvalMode), ["plan","accept-edits"].contains(requested.mode), status.roots.contains(where: { FileRules.within(requested.workspace,root:$0) }) else { throw MacError.message("请选择有效的模型、思考强度、审批策略及项目。") }
        try await verify()
        let _: FileListing = try await api().json("workspace",query:["cwd":requested.workspace])
        if let current = selected {
            if current.cwd != requested.workspace { try newConversation() }
            else { let value: Session = try await api().json("sessions/\(try GatewayClient.id(current.id))",method:"PATCH",body:requested.body); selected = value; sessionCache[value.id] = value }
        }
        settings = requested; var p = profile; p.settings = requested; try commit(p)
    }
    private func ensureSession() async throws -> String {
        if let selected { return selected.id }
        let key = scope, token = selectionEpoch; let current = draft; let queued = queue
        let value: Session = try await api().json("sessions",method:"POST",body:settings.body)
        guard scope == key, token == selectionEpoch else { throw MacError.message("会话选择已变化，请重新操作。") }
        var p = profile
        p.drafts[value.id] = current; p.drafts.removeValue(forKey:"new")
        if !queued.isEmpty { p.queues[value.id] = queued; p.queues.removeValue(forKey:"new") }
        try commit(p,announce:false); selected = value; sessionCache[value.id] = value; notify(); try await reload(); return value.id
    }
    public func send() async throws {
        guard pending == nil, selected?.running != true else { throw MacError.message("任务运行中请加入队列或使用立即引导；待确认消息需要先核对。") }
        let current = draft; guard !current.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !current.references.isEmpty else { return }
        try await verify(); let id = try await ensureSession(); var p = profile; p.pending = PendingSend(sessionID:id,draft:current); try commit(p); try await submitPending()
    }
    public func submitPending() async throws {
        guard let pending else { return }; try storage.save(state); try await verify(); let key = scope
        let value: Session = try await api().json("sessions/\(try GatewayClient.id(pending.sessionID))/messages",method:"POST",body:pending.body)
        guard key == scope else { return }; selected = value; sessionCache[value.id] = value; try reconcile(value); notify(); startWatch(value.id)
    }
    private func reconcile(_ session: Session) throws {
        guard let waiting = pending, waiting.sessionID == session.id, session.messages?.contains(where: { $0.id == waiting.requestID }) == true else { return }
        var p = profile; p.pending = nil
        var current = p.drafts[session.id] ?? Draft()
        if current.text == waiting.text { current.text = "" }
        current.references.removeAll { item in waiting.references.contains { $0.path == item.path } }; p.drafts[session.id] = current; try commit(p)
    }
    public func enqueue() async throws {
        guard pending == nil else { throw MacError.message("请先核对待确认发送。") }
        let current = draft; guard !current.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !current.references.isEmpty else { return }
        var p = profile; let key = selected?.id ?? "new"; p.queues[key,default:[]].append(QueuedMessage(draft:current)); p.drafts[key] = Draft(); try commit(p)
        if selected?.running != true { try await drainQueue() }
    }
    public func removeQueued(_ id: String, edit: Bool = false) throws {
        var p = profile, current = draft; let key = selected?.id ?? "new"
        if edit, let value = queue.first(where: { $0.id == id }) { current.text = value.draft.text + (current.text.isEmpty ? "" : "\n" + current.text); current.references = Array((value.draft.references + current.references.filter { ref in !value.draft.references.contains { $0.path == ref.path } }).prefix(8)); p.drafts[key] = current }
        p.queues[key]?.removeAll { $0.id == id }; try commit(p)
    }
    private func drainQueue() async throws {
        guard !draining, pending == nil, selected?.running != true, let next = queue.first else { return }
        draining = true; defer { draining = false }
        try await verify(); let id = try await ensureSession(); var p = profile
        p.pending = PendingSend(sessionID:id,requestID:next.id,draft:next.draft); p.queues[id]?.removeAll { $0.id == next.id }; try commit(p); try await submitPending()
    }
    public func steer() async throws {
        guard pending == nil else { throw MacError.message("请先核对待确认发送。") }
        let current = draft; guard !current.text.isEmpty || !current.references.isEmpty else { return }
        try await verify(); let id = try await ensureSession(); watch?.cancel()
        if selected?.running == true {
            var stopped: Session = try await api().json("sessions/\(try GatewayClient.id(id))/stop",method:"POST",body:.object([:]))
            for _ in 0..<40 where stopped.running { try await Task.sleep(nanoseconds:150_000_000); stopped = try await api().json("sessions/\(try GatewayClient.id(id))") }
            selected = stopped
            guard !stopped.running else { startWatch(id); throw MacError.message("任务还在停止中。输入已保留，请稍后重试。") }
        }
        var p = profile; p.pending = PendingSend(sessionID:id,draft:current); try commit(p); try await submitPending()
    }
    private func startWatch(_ id: String) {
        guard watchEnabled else { return }
        watch?.cancel(); let key = scope, token = selectionEpoch
        watch = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.scope == key, self.selectionEpoch == token, self.selected?.id == id, let client = self.client else { return }
                do {
                    try await client.snapshots(id) { [weak self] snapshot in
                        guard let self, !Task.isCancelled, self.scope == key, self.selectionEpoch == token, self.selected?.id == id else { return }
                        guard snapshot.revision >= (self.selected?.revision ?? 0) else { return }
                        self.selected = snapshot; self.sessionCache[id] = snapshot; self.streamError = nil
                        self.connectionLabel = !(snapshot.approvals ?? []).isEmpty ? "等待审批" : snapshot.running ? "AGY 正在工作" : "已就绪"
                        try self.reconcile(snapshot); self.notify()
                    }
                    failures = 0
                    if self.pending == nil, self.selected?.running != true, (self.selected?.approvals ?? []).isEmpty, self.selected?.error.isEmpty == true { try await self.drainQueue() }
                } catch {
                    if Task.isCancelled { return }; failures = min(failures + 1,5); self.streamError = "会话连接暂时中断，正在重新读取；不会自动重发消息。"; self.notify()
                }
                try? await Task.sleep(nanoseconds:UInt64(max(1,failures)) * 1_000_000_000)
            }
        }
    }
    public func stop() async throws { guard let current = selected else { return }; try await verify(); let result: Session = try await api().json("sessions/\(try GatewayClient.id(current.id))/stop",method:"POST",body:.object([:])); selected = result; notify() }
    public func approve(_ approval: Approval, allow: Bool) async throws {
        guard selected?.id == approval.sessionID else { throw MacError.message("审批不属于当前会话。") }; try await verify()
        let value: Session = try await api().json("sessions/\(try GatewayClient.id(approval.sessionID))/approvals/\(try GatewayClient.id(approval.id))",method:"POST",body:.object(["decision":.string(allow ? "allow":"deny")]))
        if value.id == selected?.id { selected = value; notify() }
    }
    public func browse(scope: String = "workspace", path: String = "", root: String? = nil) async throws -> FileListing {
        guard status?.capabilities.fileBrowser == true else { throw MacError.message("网关暂不支持文件浏览，请更新服务器网关。") }
        if let selected, root == nil { return try await api().json("sessions/\(try GatewayClient.id(selected.id))/entries",query:["scope":scope,"path":path]) }
        if scope != "workspace" { return FileListing(root:"",path:"",entries:[]) }
        return try await api().json("workspace",query:["cwd":root ?? settings.workspace,"path":path])
    }
    public func upload(_ url: URL, reference: Bool = true) async throws {
        try await verify(); let id = try await ensureSession(); let item = try await api().upload(url,sessionID:id)
        if reference, selected?.id == id, let path = item.path { try addReference(FileReference(path:path,label:"上传/" + item.name,directory:false)) }
    }
    public func download(_ path: String, sessionID: String? = nil, snapshot: Bool = false) async throws -> URL {
        try await verify(); let id: String
        if let sessionID { id = sessionID } else { id = try await ensureSession() }
        return try await api().download(path,sessionID:id,snapshot:snapshot)
    }
    public func limits() async throws -> LimitReply { try await api().json("limits",query:["refresh":"1"]) }
    public func refreshModels() async throws { let value: ModelReply = try await api().json("models",query:["refresh":"1"]); families = value.families; notify() }
    public func rename(_ session: Session, to name: String) async throws {
        try await verify(); let _: Session = try await api().json("sessions/\(try GatewayClient.id(session.id))",method:"PATCH",body:.object(["name":.string(name)])); try await reload()
    }
    public func delete(_ session: Session) async throws {
        guard pending?.sessionID != session.id else { throw MacError.message("请先核对该会话待确认发送。") }; try await verify()
        let _: JSONValue = try await api().json("sessions/\(try GatewayClient.id(session.id))",method:"DELETE")
        var p = profile; p.drafts.removeValue(forKey:session.id); p.queues.removeValue(forKey:session.id); try commit(p)
        if selected?.id == session.id { try newConversation() }; try await reload()
    }
    public func rememberBuild(_ plan: BuildPlan) throws { var p = profile; p.build = plan; try commit(p) }
    public func saveSkill(_ skill: Skill) throws { var p = profile; p.skills.removeAll { $0.id == skill.id }; p.skills.append(skill); try commit(p) }
    public func removeSkill(_ id: String) throws { var p = profile; p.skills.removeAll { $0.id == id }; try commit(p) }
}
