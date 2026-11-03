#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import AGYMacCore

@MainActor struct ChatView: View {
    @EnvironmentObject var store: MacStore
    @State private var following = true
    @State private var visibleCount = 80
    @State private var dropping = false
    @State private var workflows = false
    @State private var scrollRequest = UUID()
    private var session: Session? { store.engine.selected }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Button { store.showTaskOptions = true } label: { Label(store.engine.settings.approvalMode == "turbo" ? "Turbo 自动执行":"Restriction 逐项审批",systemImage:store.engine.settings.approvalMode == "turbo" ? "bolt":"checkmark.shield") }
                Text(store.engine.settings.mode == "plan" ? "先做计划":"直接实施").foregroundStyle(.secondary)
                Spacer()
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal,24).padding(.vertical,10)
            if (session?.messages ?? []).isEmpty { welcome.frame(maxWidth:.infinity,maxHeight:.infinity) } else { transcript }
            if !following { Button { following = true; scrollRequest = UUID() } label: { Label("回到最新",systemImage:"arrow.down") }.buttonStyle(.bordered).controlSize(.small).padding(.bottom,8) }
            composer
        }
        .onChange(of:session?.id) { _ in following = true; visibleCount = 80 }
    }
    private var welcome: some View {
        ScrollView {
            VStack(spacing:18) {
                BrandMark(size:52)
                Text("今天，一起完成什么？").font(.largeTitle.weight(.semibold))
                Text("从当前项目开始，或上传需要处理的资料。").foregroundStyle(.secondary)
                HStack(spacing:12) {
                    WelcomeAction(title:"梳理项目",detail:"找到结构与入口",icon:"square.stack.3d.up") { store.insert("请先阅读当前项目，说明整体结构和主要入口。\n") }
                    WelcomeAction(title:"上传资料",detail:"图片、文档与代码",icon:"paperclip") { store.run { try await store.upload() } }
                    WelcomeAction(title:"浏览文件",detail:"引用文件或文件夹",icon:"folder") { store.page = .files }
                }.padding(.top,10)
            }.frame(maxWidth:660).padding(32).padding(.top,55).frame(maxWidth:.infinity)
        }
    }
    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:26) {
                    if let messages = session?.messages, messages.count > visibleCount { Button("加载更早的消息（\(messages.count-visibleCount)）") { let first = Array(messages.suffix(visibleCount)).first?.id; following = false; visibleCount += 80; if let first { DispatchQueue.main.async { reader.scrollTo(first,anchor:.top) } } }.frame(maxWidth:.infinity) }
                    ForEach(Array((session?.messages ?? []).suffix(visibleCount))) { message in MessageView(message:message,sessionID:session?.id ?? "").id(message.id) }
                    Color.clear.frame(height:1).id("tail")
                }.frame(maxWidth:900).padding(.horizontal,28).padding(.vertical,20).frame(maxWidth:.infinity)
                    .background(ScrollInteractionObserver { atBottom in following = atBottom })
            }
            .onAppear { if following { reader.scrollTo("tail",anchor:.bottom) } }
            .onChange(of:session?.revision) { _ in if following { DispatchQueue.main.async { reader.scrollTo("tail",anchor:.bottom) } } }
            .onChange(of:scrollRequest) { _ in reader.scrollTo("tail",anchor:.bottom) }
            .onChange(of:session?.id) { _ in following = true; DispatchQueue.main.async { reader.scrollTo("tail",anchor:.bottom) } }
        }
    }
    private var composer: some View {
        VStack(spacing:9) {
            if let pending = store.engine.pending {
                HStack { Label("发送结果待确认",systemImage:"exclamationmark.arrow.triangle.2.circlepath"); Spacer(); Button("核对会话") { store.run { try await store.engine.select(pending.sessionID) } }; Button("按原编号重试") { store.run { try await store.engine.submitPending() } } }.font(.caption).padding(10).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10))
            }
            if !store.engine.queue.isEmpty { ScrollView { VStack(alignment:.leading,spacing:8) { ForEach(store.engine.queue) { item in HStack { Image(systemName:"list.bullet"); Text(item.draft.text.isEmpty ? "文件引用":item.draft.text).lineLimit(2); Spacer(); Button("编辑") { store.run { try store.engine.removeQueued(item.id,edit:true) } }; Button { store.run { try store.engine.removeQueued(item.id) } } label: { Image(systemName:"xmark") } } } }.font(.caption) }.frame(maxHeight:95).padding(8).background(Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:10)) }
            if !(session?.approvals ?? []).isEmpty { ScrollView { VStack { ForEach(session?.approvals ?? []) { approval in ApprovalView(approval:approval) } } }.frame(maxHeight:190) }
            VStack(alignment:.leading,spacing:8) {
                if !store.engine.draft.references.isEmpty { ScrollView(.horizontal) { HStack { ForEach(store.engine.draft.references) { item in Button { store.run { try store.engine.removeReference(item.path) } } label: { Label("@ " + item.label + "  ×",systemImage:item.directory ? "folder":"doc") }.buttonStyle(.bordered).controlSize(.small) } } } }
                TextEditor(text:$store.text).font(.body).scrollContentBackground(.hidden).frame(height:64).disabled(store.busy || store.engine.pending != nil)
                    .overlay(alignment:.topLeading) { if store.text.isEmpty { Text("描述任务，或输入 @ 引用文件与文件夹…").font(.body).foregroundStyle(.tertiary).padding(.top,8).padding(.leading,4).allowsHitTesting(false) } }
                    .onChange(of:store.text) { text in if text.hasSuffix("@"), !store.showReferences { store.mention() }; if text == "/" { workflows = true } }
                HStack(spacing:8) {
                    Button { store.run { try await store.upload() } } label: { Image(systemName:"paperclip") }.help("上传文件")
                    Button("@") { store.mention() }.help("引用文件或整个文件夹")
                    Button { workflows = true } label: { Image(systemName:"slash.circle") }.help("快捷工作流")
                        .popover(isPresented:$workflows) { VStack(alignment:.leading,spacing:8) { Text("快捷工作流").font(.headline); ForEach(WorkflowCatalog.items) { item in Button(item.name) { if store.text == "/" { store.text = "" }; store.insert(item.prompt); workflows = false } }; Button("管理项目技能…") { store.page = .skills; workflows = false } }.padding(18).frame(width:280) }
                    Button { store.showTaskOptions = true } label: { Text(modelTitle).lineLimit(1); Image(systemName:"chevron.down").font(.caption2) }.help("先选模型，再选思考强度").disabled(store.busy || session?.running == true)
                    Spacer(minLength:4)
                    if session?.running == true {
                        Button { store.run { try await store.engine.stop() } } label: { Image(systemName:"stop.fill") }.help("停止任务")
                        Button("立即引导") { store.steer() }.disabled(store.text.isEmpty && store.engine.draft.references.isEmpty)
                    }
                    Button { if session?.running == true { store.queue() } else { store.send() } } label: { Label(session?.running == true ? "加入队列":"发送",systemImage:session?.running == true ? "text.badge.plus":"arrow.up") }.buttonStyle(.borderedProminent).keyboardShortcut(.return,modifiers:.command).disabled(store.busy || store.engine.pending != nil || (store.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && store.engine.draft.references.isEmpty))
                }.controlSize(.small).disabled(store.busy)
            }.padding(14).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:16)).overlay(RoundedRectangle(cornerRadius:16).stroke(dropping ? Color.accentColor:Color.secondary.opacity(0.18),lineWidth:dropping ? 2:1))
                .onDrop(of:[UTType.fileURL],isTargeted:$dropping) { providers in
                    guard providers.count <= 8 else { store.error = "每批最多上传 8 个文件。"; return false }
                    Task { @MainActor in
                        var urls: [URL] = []
                        for provider in providers {
                            let url: URL? = await withCheckedContinuation { continuation in provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                                continuation.resume(returning:(item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) })
                            } }
                            if let url { urls.append(url) }
                        }
                        guard urls.count == providers.count else { store.error = "部分拖入的文件未能读取。"; return }
                        store.run { try await store.upload(urls) }
                    }; return true
                }
            Text("⌘ Enter 发送 · Enter 换行 · 支持拖入文件").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:940).padding(.horizontal,24).padding(.bottom,14).frame(maxWidth:.infinity)
    }
    private var modelTitle: String { (store.engine.families.first { $0.id == store.engine.settings.model }?.name ?? "选择模型") + " · " + FileRules.effort(store.engine.settings.effort) }
}
@MainActor struct WelcomeAction: View {
    let title: String, detail: String, icon: String; let action: () -> Void
    var body: some View { Button(action:action) { VStack(alignment:.leading,spacing:9) { Image(systemName:icon).font(.title3); Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }.padding(16).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.bordered) }
}
@MainActor struct ApprovalView: View {
    @EnvironmentObject var store: MacStore
    let approval: Approval
    var body: some View { VStack(alignment:.leading,spacing:8) {
        Label("等待审批 · " + approval.tool,systemImage:"hand.raised").font(.headline)
        DisclosureGroup("查看实际参数") { ScrollView { Text(approval.parameters.pretty).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:100) }
        HStack { Button("拒绝",role:.destructive) { store.run { try await store.engine.approve(approval,allow:false) } }; Button("允许这一次") { store.run { try await store.engine.approve(approval,allow:true) } }.buttonStyle(.borderedProminent); Spacer(); Text("仅批准当前操作").font(.caption).foregroundStyle(.secondary) }
    }.padding(12).background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:12)) }
}
@MainActor struct MessageView: View {
    @EnvironmentObject var store: MacStore
    let message: ChatMessage, sessionID: String
    private var artifacts: [ArtifactReference] { guard let origin = store.engine.client?.credentials.address else { return [] }; return RemoteLinks.artifacts(message,origin:origin,cwd:store.engine.settings.workspace) }
    var body: some View {
        HStack(alignment:.top) {
            if message.role == "user" { Spacer(minLength:65) }
            VStack(alignment:.leading,spacing:12) {
                HStack(spacing:7) { if message.role != "user" { BrandMark(size:18) }; Text(message.role == "user" ? "你":"AGY").font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer(); Button { NativeFiles.paste(message.text) } label: { Image(systemName:"doc.on.doc") }.buttonStyle(.borderless).help("复制消息") }
                if message.role == "assistant", store.engine.profile.presentation != "结论优先" { process }
                ForEach(MessageParts.blocks(message.text)) { block in
                    if let language = block.language { CodeBlock(text:block.text,language:language) }
                    else { Text(.init(block.text)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).environment(\.openURL,OpenURLAction(handler:store.open)) }
                }
                if message.role == "assistant", store.engine.profile.presentation == "结论优先", !(message.tools ?? []).isEmpty || !(message.steps ?? []).isEmpty { DisclosureGroup("查看思考与工具") { ProcessView(message:message,expanded:false) } }
                if !artifacts.isEmpty { VStack(alignment:.leading,spacing:10) { Text("文件与产物").font(.caption.weight(.medium)).foregroundStyle(.secondary); ForEach(artifacts) { ArtifactView(artifact:$0,sessionID:sessionID) } }.padding(.top,4) }
            }.padding(message.role == "user" ? 16:4).background(message.role == "user" ? Color.secondary.opacity(0.09):Color.clear,in:RoundedRectangle(cornerRadius:16))
            if message.role != "user" { Spacer(minLength:0) }
        }
    }
    @ViewBuilder private var process: some View { if !(message.steps ?? []).isEmpty || !(message.tools ?? []).isEmpty { ProcessView(message:message,expanded:store.engine.profile.presentation == "原版") } }
}
@MainActor struct ProcessView: View {
    let message: ChatMessage, expanded: Bool
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            ForEach(Array((message.steps ?? []).enumerated()),id:\.offset) { _,step in
                if let thinking = step.thinking, !thinking.isEmpty { DisclosureGroup("思考摘要") { Text(thinking).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) } }
                if !step.text.isEmpty && step.text != message.text { if expanded { Text(step.text).font(.callout).textSelection(.enabled) } else { DisclosureGroup("过程摘要") { Text(step.text).font(.callout).textSelection(.enabled) } } }
            }
            ForEach(message.tools ?? []) { tool in ToolView(tool:tool,expanded:expanded) }
        }.font(.callout)
    }
}
@MainActor struct ToolView: View {
    let tool: ToolCall
    @State private var expanded: Bool
    init(tool: ToolCall, expanded: Bool) { self.tool = tool; _expanded = State(initialValue:expanded) }
    var body: some View { DisclosureGroup(isExpanded:$expanded) { ScrollView { Text(tool.parameters.pretty + "\n" + tool.output).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:220) } label: { Label(tool.name + " · " + tool.state,systemImage:tool.isError == true ? "exclamationmark.triangle":"terminal") }.padding(10).background(Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:10)) }
}
@MainActor struct CodeBlock: View {
    let text: String, language: String
    @State private var wrap = false
    var body: some View { VStack(alignment:.leading,spacing:0) {
        HStack { Text(language.isEmpty ? "code":language).font(.caption).foregroundStyle(.secondary); Spacer(); Toggle("换行",isOn:$wrap).toggleStyle(.checkbox).font(.caption); Button { NativeFiles.paste(text) } label: { Image(systemName:"doc.on.doc") }.buttonStyle(.borderless) }.padding(9)
        Divider()
        ScrollView(wrap ? [.vertical]:[.horizontal,.vertical]) { Text(text).font(.system(.callout,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:!wrap,vertical:true).frame(maxWidth:wrap ? .infinity:nil,alignment:.leading).padding(12) }.frame(maxHeight:360)
    }.background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:10)) }
}
@MainActor struct ArtifactView: View {
    @EnvironmentObject var store: MacStore
    let artifact: ArtifactReference, sessionID: String
    @State private var image: NSImage?
    var body: some View { HStack(spacing:12) {
        if artifact.image { Button { store.run { if let url = await store.image(artifact,sessionID:sessionID) { store.previewURL = url } else { throw MacError.message("图片暂未能预览，可尝试下载。") } } } label: { Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Image(systemName:"photo").font(.title) } }.frame(width:110,height:82) }.buttonStyle(.plain).task(id:artifact.path) {
            if let url = await store.image(artifact,sessionID:sessionID), let source = CGImageSourceCreateWithURL(url as CFURL,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:320] as CFDictionary) { image = NSImage(cgImage:cg,size:NSSize(width:CGFloat(cg.width),height:CGFloat(cg.height))) }
        } } else { Image(systemName:"doc").font(.title2).frame(width:28) }
        VStack(alignment:.leading,spacing:4) { Text(artifact.name).lineLimit(2); if artifact.image { Text("点按放大预览").font(.caption).foregroundStyle(.secondary) } }; Spacer()
        Button { store.run { try await store.download(artifact,sessionID:sessionID) } } label: { Image(systemName:"arrow.down.circle") }.help("下载到 Mac")
    }.padding(10).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:12)) }
}

/// Observes actual wheel gestures only. Layout, image loading and completed SSE
/// snapshots cannot toggle follow mode or pull a reader back to the bottom.
@MainActor struct ScrollInteractionObserver: NSViewRepresentable {
    let action: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action:action) }
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.view = view; context.coordinator.start(); return view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator {
        weak var view: NSView?; var monitor: Any?; var action: (Bool) -> Void
        init(action:@escaping (Bool)->Void) { self.action = action }
        func start() { monitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDragged]) { [weak self] event in
            guard let self, let scroll = self.view?.enclosingScrollView, event.window == scroll.window, scroll.bounds.contains(scroll.convert(event.locationInWindow,from:nil)) else { return event }
            self.action(false)
            DispatchQueue.main.async { [weak self,weak scroll] in guard let self, let scroll, let document = scroll.documentView else { return }; let distance = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.maxY : scroll.contentView.bounds.minY; self.action(distance < 8) }
            return event
        } }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
#endif
