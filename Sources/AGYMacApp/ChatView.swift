#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import AGYMacCore

/// Caches parsed message blocks, Markdown AttributedStrings, process summaries, inline image references,
/// and session-level Codex file change summaries so scrolling and switching sessions never block the main thread.
@MainActor final class MessageBlockCache {
    static let shared = MessageBlockCache()

    struct RenderedBlock: Identifiable {
        let id: Int
        let text: String
        let language: String?
        let attributed: AttributedString?
    }

    struct CachedMessageRender {
        let blocks: [RenderedBlock]
        let processSummary: TurnProcessSummary
        let inlineImages: [ArtifactReference]
    }

    struct CachedSessionSummary {
        let changeSummary: SessionChangeSummary
        let artifacts: [ArtifactReference]
    }

    private var cache: [String: CachedMessageRender] = [:]
    private var sessionCache: [String: CachedSessionSummary] = [:]

    func render(for message: ChatMessage, origin: URL?, cwd: String) -> CachedMessageRender {
        let toolCount = message.tools?.count ?? 0
        let lastToolSig = message.tools?.last.map { "\($0.id):\($0.state):\($0.output.utf8.count)" } ?? ""
        let stepCount = message.steps?.count ?? 0
        let lastStepSig = message.steps?.last.map { "\($0.index):\($0.text.utf8.count):\($0.thinking?.utf8.count ?? 0)" } ?? ""
        let key = "\(message.id)#\(message.text.utf8.count)#\(toolCount)#\(lastToolSig)#\(stepCount)#\(lastStepSig)#\(cwd)#\(origin?.absoluteString ?? "")"
        if let existing = cache[key] { return existing }

        let rawBlocks = MessageParts.blocks(message.text)
        let renderedBlocks = rawBlocks.map { block -> RenderedBlock in
            if block.language != nil {
                return RenderedBlock(id: block.id, text: block.text, language: block.language, attributed: nil)
            }
            let attr = (try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block.text)
            return RenderedBlock(id: block.id, text: block.text, language: nil, attributed: attr)
        }
        let summary = RemoteLinks.processSummary(for: message, cwd: cwd)
        let images: [ArtifactReference]
        if let origin {
            images = RemoteLinks.messageImages(message, origin: origin, cwd: cwd)
        } else {
            images = []
        }

        let entry = CachedMessageRender(blocks: renderedBlocks, processSummary: summary, inlineImages: images)
        if cache.count > 500 { cache.removeAll(keepingCapacity: true) }
        cache[key] = entry
        return entry
    }

    func prewarm(messages: [ChatMessage], origin: URL?, cwd: String) {
        for message in messages {
            _ = render(for: message, origin: origin, cwd: cwd)
        }
    }

    func sessionSummary(
        sessionID: String,
        revision: Int,
        messages: [ChatMessage],
        cwd: String,
        externalDiffs: [String: FileDiffRecord],
        lineCounts: [String: Int],
        origin: URL?
    ) -> CachedSessionSummary {
        let lastMsgSig = messages.last.map { "\($0.id):\($0.text.utf8.count):\($0.tools?.count ?? 0)" } ?? ""
        let key = "\(sessionID)#\(revision)#\(messages.count)#\(lastMsgSig)#\(externalDiffs.count)#\(lineCounts.count)#\(cwd)#\(origin?.absoluteString ?? "")"
        if let existing = sessionCache[key] { return existing }

        let changes = RemoteLinks.sessionChanges(
            messages,
            cwd: cwd,
            externalDiffs: externalDiffs,
            downloadedLineCounts: lineCounts
        )
        let artifacts: [ArtifactReference]
        if let origin {
            let modified = Set(changes.changes.map(\.path))
            artifacts = RemoteLinks.sessionArtifacts(messages, origin: origin, cwd: cwd, excluding: modified)
        } else {
            artifacts = []
        }
        let result = CachedSessionSummary(changeSummary: changes, artifacts: artifacts)
        if sessionCache.count > 64 { sessionCache.removeAll(keepingCapacity: true) }
        sessionCache[key] = result
        return result
    }
}

/// Isolated scroll state model so toggling `following` during trackpad scrolling
/// only updates the small floating button and NEVER invalidates `ChatView.body` or `transcript`.
@MainActor final class TranscriptScrollModel: ObservableObject {
    @Published var following: Bool = true
    var onScrollToBottomImmediate: (() -> Void)?
    var onScrollToBottomSettled: (() -> Void)?

    func jumpToBottomNow() {
        if !following { following = true }
        onScrollToBottomImmediate?()
    }

    func scrollToBottomForNewContent() {
        if !following { following = true }
        onScrollToBottomSettled?()
    }
}

@MainActor struct ScrollToBottomOverlay: View {
    @ObservedObject var scrollModel: TranscriptScrollModel
    var body: some View {
        if !scrollModel.following {
            Button {
                scrollModel.jumpToBottomNow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    Text("回到最新")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(AppTheme.elevatedBg, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.strongBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
        }
    }
}

/// Custom tactile pill button used in the chat composer and floating bars.
@MainActor struct ComposerPillButton: View {
    let title: String
    let icon: String
    var badge: String? = nil
    var tone: Tone = .neutral
    var isDisabled: Bool = false
    let action: () -> Void

    enum Tone {
        case neutral
        case primary
        case danger
    }

    private var bg: Color {
        switch tone {
        case .neutral: return AppTheme.elevatedBg
        case .primary: return isDisabled ? AppTheme.elevatedBg : Color.accentColor
        case .danger: return Color.red.opacity(0.14)
        }
    }

    private var fg: Color {
        if isDisabled { return Color.secondary.opacity(0.55) }
        switch tone {
        case .neutral: return Color.primary.opacity(0.88)
        case .primary: return Color.white
        case .danger: return Color.red
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .neutral: return AppTheme.border
        case .primary: return isDisabled ? AppTheme.border : Color.white.opacity(0.14)
        case .danger: return Color.red.opacity(0.32)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: tone == .primary ? .semibold : .medium))
                        .lineLimit(1)
                }
                if let badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .opacity(0.75)
                }
            }
            .foregroundStyle(fg)
            .padding(.horizontal, tone == .primary ? 12 : 10)
            .frame(height: 28)
            .background(bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(strokeColor, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

@MainActor struct ChatView: View {
    @EnvironmentObject var store: MacStore
    @StateObject private var scrollModel = TranscriptScrollModel()
    @State private var visibleCount = 24
    @State private var dropping = false
    @State private var workflows = false

    private var session: Session? { store.engine.selected }
    private var messages: [ChatMessage] { session?.messages ?? [] }
    private var cachedSessionSummary: MessageBlockCache.CachedSessionSummary {
        let sid = session?.id ?? ""
        return MessageBlockCache.shared.sessionSummary(
            sessionID: sid,
            revision: session?.revision ?? 0,
            messages: messages,
            cwd: store.engine.settings.workspace,
            externalDiffs: store.sessionDiffs[sid] ?? [:],
            lineCounts: store.sessionLineCounts[sid] ?? [:],
            origin: store.engine.client?.credentials.address
        )
    }

    var body: some View {
        VStack(spacing:0) {
            if messages.isEmpty {
                welcome.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                transcript
                    .overlay(alignment: .bottom) {
                        ScrollToBottomOverlay(scrollModel: scrollModel)
                    }
            }
            composer
        }
        .background(AppTheme.canvasBg)
        .onChange(of:session?.id) { _ in
            visibleCount = 24
            scrollModel.scrollToBottomForNewContent()
        }
        .onChange(of:messages.count) { _ in
            if scrollModel.following { scrollModel.scrollToBottomForNewContent() }
        }
        .onChange(of:session?.revision) { _ in
            if scrollModel.following { scrollModel.scrollToBottomForNewContent() }
        }
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
        let slice = Array(messages.suffix(visibleCount))
        let lastID = messages.last?.id ?? ""
        let sessionRunning = session?.running == true
        let sid = session?.id ?? ""
        let origin = store.engine.client?.credentials.address
        let cwd = store.engine.settings.workspace
        let forceExpanded = store.engine.profile.presentation == "原版"
        // Uses a pre-realized VStack (instead of LazyVStack) for the 24 visible messages so off-screen
        // bottom messages are never unmounted when scrolling up — eliminating the blank flash on "回到最新".
        return ScrollView {
            VStack(alignment:.leading,spacing:20) {
                if messages.count > visibleCount {
                    HStack {
                        Spacer()
                        ComposerPillButton(
                            title: "加载更早的消息（还有 \(messages.count - visibleCount) 条）",
                            icon: "clock.arrow.circlepath"
                        ) {
                            scrollModel.following = false
                            visibleCount += 24
                        }
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }
                ForEach(slice) { message in
                    MessageView(
                        message: message,
                        sessionID: sid,
                        isActivelyRunning: sessionRunning && message.id == lastID,
                        durationSeconds: store.turnDurations[message.id],
                        forceExpanded: forceExpanded,
                        origin: origin,
                        workspace: cwd
                    )
                    .equatable()
                    .id(message.id)
                }
                Color.clear.frame(height: 2).id("tail")
            }
            .frame(maxWidth:860)
            .padding(.horizontal,28)
            .padding(.vertical,20)
            .frame(maxWidth:.infinity)
            .background(
                TranscriptScrollBridge(
                    scrollModel: scrollModel,
                    sessionID: sid,
                    messageCount: messages.count
                )
            )
        }
        .environment(\.openURL, OpenURLAction(handler: store.open))
    }

    private var composer: some View {
        let imageRefs = store.engine.draft.references.filter(\.isImage)
        let fileRefs = store.engine.draft.references.filter { !$0.isImage }
        let localBuildURLs = store.hybridWorker.localOutputs
        let summaryInfo = cachedSessionSummary
        let canSend = !(store.busy || store.engine.pending != nil || (store.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && store.engine.draft.references.isEmpty))
        return VStack(spacing:8) {
            if !summaryInfo.changeSummary.isEmpty || !summaryInfo.artifacts.isEmpty || !localBuildURLs.isEmpty {
                CodexChangesFloatingBar(
                    summary: summaryInfo.changeSummary,
                    artifacts: summaryInfo.artifacts,
                    localOutputs: localBuildURLs,
                    sessionID: session?.id ?? ""
                )
            }
            if let pending = store.engine.pending {
                HStack(spacing: 10) {
                    Label("发送结果待确认",systemImage:"exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                    Spacer()
                    ComposerPillButton(title: "核对会话", icon: "magnifyingglass") {
                        store.run { try await store.engine.select(pending.sessionID) }
                    }
                    ComposerPillButton(title: "按原编号重试", icon: "arrow.clockwise", tone: .primary) {
                        store.run { try await store.engine.submitPending() }
                    }
                }
                .padding(10)
                .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
            }
            if !store.engine.queue.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(store.engine.queue) { item in
                        HStack(spacing: 8) {
                            Image(systemName:"list.bullet").foregroundStyle(.secondary)
                            Text(item.draft.text.isEmpty ? "文件引用":item.draft.text).lineLimit(1)
                            Spacer()
                            ComposerPillButton(title: "编辑", icon: "pencil") {
                                store.run { try store.engine.removeQueued(item.id,edit:true) }
                            }
                            ComposerPillButton(title: "", icon: "xmark") {
                                store.run { try store.engine.removeQueued(item.id) }
                            }
                        }
                    }
                }
                .font(.caption)
                .padding(10)
                .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.border, lineWidth: 1))
            }
            if !(session?.approvals ?? []).isEmpty {
                VStack(spacing: 8) {
                    ForEach(session?.approvals ?? []) { approval in
                        ApprovalView(approval:approval)
                    }
                }
            }
            VStack(alignment:.leading,spacing:10) {
                if !imageRefs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(imageRefs) { item in
                                DraftImageAttachmentCard(reference: item, sessionID: session?.id ?? "") {
                                    store.run { try store.engine.removeReference(item.path) }
                                }
                            }
                        }.padding(.vertical, 2)
                    }
                }
                if !fileRefs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(fileRefs) { item in
                                Button { store.run { try store.engine.removeReference(item.path) } } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: item.directory ? "folder" : "doc")
                                            .font(.system(size: 11))
                                        Text("@" + item.label)
                                            .font(.system(size: 12, weight: .medium))
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                ComposerInputView(
                    text: $store.text,
                    placeholder: "描述任务，或输入 @ 引用文件与文件夹…",
                    isEditable: !(store.busy || store.engine.pending != nil),
                    onPasteMedia: { store.pasteClipboardMedia() },
                    onTriggerMention: {
                        if !store.showReferences { store.mention() }
                    },
                    onTriggerWorkflow: {
                        workflows = true
                    },
                    onSubmit: {
                        guard canSend else { return }
                        if session?.running == true { store.queue() } else { store.send() }
                    }
                )
                .frame(height: 68)

                // Refined composer action bar with custom tactile pills
                HStack(spacing: 8) {
                    ComposerPillButton(title: "附件", icon: "paperclip", isDisabled: store.busy) {
                        store.run { try await store.upload() }
                    }

                    ComposerPillButton(title: "引用", icon: "at", isDisabled: store.busy) {
                        store.mention()
                    }

                    ComposerPillButton(title: "工作流", icon: "command", isDisabled: store.busy) {
                        workflows = true
                    }
                    .popover(isPresented: $workflows) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("快捷工作流")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.bottom, 2)
                            ForEach(WorkflowCatalog.items) { item in
                                Button {
                                    if store.text == "/" { store.text = "" }
                                    store.insert(item.prompt)
                                    workflows = false
                                } label: {
                                    HStack {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.accentColor)
                                        Text(item.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                            Divider().padding(.vertical, 2)
                            Button {
                                store.page = .skills
                                workflows = false
                            } label: {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 11))
                                    Text("管理项目技能…")
                                        .font(.system(size: 12))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(14)
                        .frame(width: 260)
                        .background(AppTheme.cardBg)
                    }

                    Button {
                        store.showTaskOptions = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(modelTitle)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.busy || session?.running == true)

                    Spacer(minLength: 6)

                    if session?.running == true {
                        ComposerPillButton(title: "停止", icon: "stop.fill", tone: .danger, isDisabled: store.busy) {
                            store.run { try await store.engine.stop() }
                        }
                        ComposerPillButton(
                            title: "立即引导",
                            icon: "arrow.uturn.up",
                            isDisabled: store.busy || (store.text.isEmpty && store.engine.draft.references.isEmpty)
                        ) {
                            store.steer()
                        }
                    }

                    ComposerPillButton(
                        title: session?.running == true ? "加入队列" : "发送",
                        icon: session?.running == true ? "text.badge.plus" : "arrow.up",
                        badge: "⌘↩",
                        tone: .primary,
                        isDisabled: !canSend
                    ) {
                        if session?.running == true { store.queue() } else { store.send() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(14)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(dropping ? Color.accentColor : AppTheme.strongBorder, lineWidth: dropping ? 2 : 1)
            )
            .onDrop(of:[UTType.fileURL, UTType.image],isTargeted:$dropping) { providers in
                guard providers.count <= 8 else { store.error = "每批最多上传 8 个文件。"; return false }
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                            let url: URL? = await withCheckedContinuation { continuation in provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                                continuation.resume(returning:(item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation:$0,relativeTo:nil) })
                            } }
                            if let url { urls.append(url); continue }
                        }
                        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                            let url: URL? = await withCheckedContinuation { continuation in provider.loadItem(forTypeIdentifier:UTType.image.identifier,options:nil) { item,_ in
                                if let u = item as? URL { continuation.resume(returning: u); return }
                                let imgData = (item as? Data) ?? (item as? NSImage)?.tiffRepresentation
                                if let d = imgData, let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) {
                                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("拖入图片-\(UUID().uuidString.prefix(6)).png")
                                    if (try? png.write(to: tmp, options: .atomic)) != nil { continuation.resume(returning: tmp); return }
                                }
                                continuation.resume(returning: nil)
                            } }
                            if let url { urls.append(url) }
                        }
                    }
                    guard !urls.isEmpty else { store.error = "拖入的文件未能读取。"; return }
                    store.run { try await store.upload(urls) }
                }; return true
            }
            Text("⌘ Enter 发送 · Enter 换行 · 支持 ⌘V 粘贴图片与拖入文件")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth:860)
        .padding(.horizontal,28)
        .padding(.bottom,14)
        .frame(maxWidth:.infinity)
    }
    private var modelTitle: String { (store.engine.families.first { $0.id == store.engine.settings.model }?.name ?? "选择模型") + " · " + FileRules.effort(store.engine.settings.effort) }
}

/// Native AppKit text editor with stable IME cursor handling, localized context menu, and clipboard image interception.
@MainActor struct ComposerInputView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEditable: Bool
    let onPasteMedia: () -> Bool
    let onTriggerMention: () -> Void
    let onTriggerWorkflow: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 68))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true

        let contentSize = scroll.contentSize
        let textView = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        let font = NSFont.systemFont(ofSize: 14)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.placeholderString = placeholder
        textView.onPasteMedia = onPasteMedia
        textView.onSubmit = onSubmit
        textView.string = text

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        if textView.placeholderString != placeholder {
            textView.placeholderString = placeholder
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        textView.onPasteMedia = onPasteMedia
        textView.onSubmit = onSubmit

        // Never overwrite NSTextView while Chinese IME markedText is active or when the user's keystroke already matches.
        guard !textView.hasMarkedText(), !context.coordinator.isEditingInternally else { return }
        if textView.string != text {
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.needsDisplay = true
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInputView
        var isEditingInternally = false
        init(_ parent: ComposerInputView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerNSTextView else { return }
            textView.needsDisplay = true
            guard !textView.hasMarkedText() else { return }
            let current = textView.string
            if parent.text != current {
                isEditingInternally = true
                parent.text = current
                isEditingInternally = false
                if current.hasSuffix("@") {
                    parent.onTriggerMention()
                } else if current == "/" {
                    parent.onTriggerWorkflow()
                }
            }
        }
    }
}

@MainActor final class ComposerNSTextView: NSTextView {
    var placeholderString: String = "" { didSet { needsDisplay = true } }
    var onPasteMedia: (() -> Bool)?
    var onSubmit: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholderString.isEmpty else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 4
        let font = self.font ?? .systemFont(ofSize: 14)
        let style = defaultParagraphStyle ?? NSParagraphStyle.default
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: style
        ]
        let rect = NSRect(
            x: origin.x + padding,
            y: origin.y,
            width: max(0, bounds.width - (origin.x + padding) * 2),
            height: max(22, bounds.height - origin.y)
        )
        (placeholderString as NSString).draw(in: rect, withAttributes: attrs)
    }

    override func paste(_ sender: Any?) {
        if onPasteMedia?() == true { return }
        super.pasteAsPlainText(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "v": paste(nil); return true
                case "c": copy(nil); return true
                case "x": cut(nil); return true
                case "a": selectAll(nil); return true
                case "z": undoManager?.undo(); return true
                default: break
                }
            } else if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
                undoManager?.redo(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "编辑")
        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(undoItem)
        menu.addItem(redoItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "剪切", action: #selector(cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "拷贝", action: #selector(copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "粘贴", action: #selector(paste(_:)), keyEquivalent: "v"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "全选", action: #selector(selectAll(_:)), keyEquivalent: "a"))
        return menu
    }
}

@MainActor struct DraftImageAttachmentCard: View {
    @EnvironmentObject var store: MacStore
    let reference: FileReference
    let sessionID: String
    let onRemove: () -> Void
    @State private var thumbnail: NSImage?
    private var artifact: ArtifactReference {
        ArtifactReference(path: reference.path, name: reference.label.replacingOccurrences(of: "上传/", with: ""), mime: "image/png")
    }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                store.run {
                    if let url = await store.image(artifact, sessionID: sessionID) {
                        store.previewURL = url
                    }
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.elevatedBg)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text(URL(fileURLWithPath: reference.path).lastPathComponent)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .frame(width: 68, height: 68)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
        .task(id: reference.path) {
            if let url = await store.image(artifact, sessionID: sessionID),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 240
               ] as CFDictionary) {
                thumbnail = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
        }
    }
}

/// Codex-style floating file changes & local hybrid build output bar positioned right above the composer.
@MainActor struct CodexChangesFloatingBar: View {
    @EnvironmentObject var store: MacStore
    let summary: SessionChangeSummary
    let artifacts: [ArtifactReference]
    let localOutputs: [URL]
    let sessionID: String
    @State private var expanded = false
    @State private var tab = "files"
    @State private var selectedFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !localOutputs.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("本机产物已就绪：\(localOutputs.map(\.lastPathComponent).joined(separator: "、"))")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            ComposerPillButton(title: "在 Finder 中显示", icon: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting(localOutputs)
                            }
                            if let firstApp = localOutputs.first(where: { $0.pathExtension == "app" }) ?? localOutputs.first {
                                ComposerPillButton(title: "直接打开", icon: "play.fill", tone: .primary) {
                                    NSWorkspace.shared.open(firstApp)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    }
                    if !summary.isEmpty && !artifacts.isEmpty {
                        HStack(spacing: 8) {
                            Picker("", selection: $tab) {
                                Text("文件变更 (\(summary.totalCount))").tag("files")
                                Text("构建与产物 (\(artifacts.count))").tag("artifacts")
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 280)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, localOutputs.isEmpty ? 10 : 2)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if (tab == "artifacts" && !artifacts.isEmpty) || summary.isEmpty {
                                ForEach(artifacts) { item in
                                    ArtifactView(artifact: item, sessionID: sessionID)
                                }
                            } else {
                                ForEach(summary.changes) { change in
                                    CodexFileChangeRow(
                                        change: change,
                                        isSelected: selectedFile == change.id,
                                        onToggle: {
                                            selectedFile = (selectedFile == change.id) ? nil : change.id
                                        },
                                        onDownload: {
                                            store.run {
                                                try await store.download(
                                                    ArtifactReference(path: change.path, name: change.name, mime: "text/plain"),
                                                    sessionID: sessionID
                                                )
                                            }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 210)
                    Rectangle().fill(AppTheme.border).frame(height: 1)
                }
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if summary.isEmpty && !artifacts.isEmpty { tab = "artifacts" }
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: summary.isEmpty ? "shippingbox" : "doc.badge.gearshape")
                            .foregroundStyle(.secondary)
                        if !summary.isEmpty {
                            Text(summary.statusText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text("+\(summary.totalAdded)")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.green)
                                Text("-\(summary.totalRemoved)")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(AppTheme.elevatedBg, in: Capsule())
                        }
                        if !localOutputs.isEmpty {
                            Text("· 本机产物已保存")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        } else if !artifacts.isEmpty {
                            Text(summary.isEmpty ? "已生成 \(artifacts.count) 项产物" : "· 产物 \(artifacts.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(expanded ? "收起明细" : "查看变更")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !localOutputs.isEmpty && !expanded {
                    ComposerPillButton(title: "在 Finder 中显示", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting(localOutputs)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.strongBorder, lineWidth: 1))
    }
}

@MainActor struct CodexFileChangeRow: View {
    let change: SessionFileChange
    let isSelected: Bool
    let onToggle: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Text(change.kind)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(change.kind == "新增" ? Color.green : Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((change.kind == "新增" ? Color.green : Color.accentColor).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        Text(change.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if change.displayPath != change.name {
                            Text(change.displayPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            Text("+\(change.addedLines)")
                                .foregroundStyle(.green)
                            Text("-\(change.removedLines)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            if isSelected {
                if !change.previewSnippet.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(change.previewSnippet.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("+") ? Color.green : (line.hasPrefix("-") ? Color.red : Color.secondary))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .background(AppTheme.canvasBg, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("路径：\(change.path) · 共修改 \(change.editCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor struct WelcomeAction: View {
    let title: String, detail: String, icon: String; let action: () -> Void
    var body: some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:9) {
                Image(systemName:icon).font(.title3).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

@MainActor struct ApprovalView: View {
    @EnvironmentObject var store: MacStore
    let approval: Approval
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("等待审批 · " + approval.tool,systemImage:"hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            DisclosureGroup("查看实际参数") {
                Text(approval.parameters.pretty)
                    .font(.system(.caption,design:.monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(8)
                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                ComposerPillButton(title: "拒绝", icon: "xmark", tone: .danger) {
                    store.run { try await store.engine.approve(approval,allow:false) }
                }
                ComposerPillButton(title: "允许这一次", icon: "checkmark", tone: .primary) {
                    store.run { try await store.engine.approve(approval,allow:true) }
                }
                Spacer()
                Text("仅批准当前操作").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

/// Pure value-type message view (zero `@EnvironmentObject` or `@State` properties)
/// so SwiftUI's `.equatable()` genuinely short-circuits evaluation during scroll and state updates.
/// Assistant turns render directly on the canvas without heavy multi-layered nested card frames.
@MainActor struct MessageView: View, Equatable {
    let message: ChatMessage
    let sessionID: String
    let isActivelyRunning: Bool
    let durationSeconds: Int?
    let forceExpanded: Bool
    let origin: URL?
    let workspace: String

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.text == rhs.message.text &&
        (lhs.message.tools?.count ?? 0) == (rhs.message.tools?.count ?? 0) &&
        lhs.message.tools?.last?.state == rhs.message.tools?.last?.state &&
        lhs.message.tools?.last?.output.utf8.count == rhs.message.tools?.last?.output.utf8.count &&
        (lhs.message.steps?.count ?? 0) == (rhs.message.steps?.count ?? 0) &&
        lhs.message.steps?.last?.thinking == rhs.message.steps?.last?.thinking &&
        lhs.message.steps?.last?.text == rhs.message.steps?.last?.text &&
        lhs.sessionID == rhs.sessionID &&
        lhs.isActivelyRunning == rhs.isActivelyRunning &&
        lhs.durationSeconds == rhs.durationSeconds &&
        lhs.forceExpanded == rhs.forceExpanded &&
        lhs.origin == rhs.origin &&
        lhs.workspace == rhs.workspace
    }

    var body: some View {
        let render = MessageBlockCache.shared.render(for: message, origin: origin, cwd: workspace)
        if message.role == "user" {
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 8) {
                    if !render.inlineImages.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(render.inlineImages) { img in
                                InlineMessageImageView(artifact: img, sessionID: sessionID)
                            }
                        }
                    }
                    ForEach(render.blocks) { block in
                        if let language = block.language {
                            CodeBlock(text: block.text, language: language)
                        } else if let attributed = block.attributed {
                            Text(attributed)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppTheme.userBubbleBg, in: RoundedRectangle(cornerRadius: 12))
                .contextMenu {
                    Button("复制消息") { NativeFiles.paste(message.text) }
                }
            }
        } else {
            // Flat, un-nested layout for Assistant turns directly on the canvas
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    BrandMark(size: 16)
                    Text("AGY")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NativeFiles.paste(message.text)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("复制")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }

                if !render.inlineImages.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(render.inlineImages) { img in
                            InlineMessageImageView(artifact: img, sessionID: sessionID)
                        }
                    }
                }

                if !render.processSummary.isEmpty {
                    TurnProcessCard(
                        summary: render.processSummary,
                        isActivelyRunning: isActivelyRunning,
                        durationSeconds: durationSeconds,
                        forceExpanded: forceExpanded
                    )
                }

                if !isActivelyRunning || render.processSummary.rounds.isEmpty {
                    ForEach(render.blocks) { block in
                        if let language = block.language {
                            CodeBlock(text: block.text, language: language)
                        } else if let attributed = block.attributed {
                            Text(attributed)
                                .font(.system(size: 14))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("复制全文") { NativeFiles.paste(message.text) }
            }
        }
    }
}

@MainActor struct InlineMessageImageView: View {
    @EnvironmentObject var store: MacStore
    let artifact: ArtifactReference
    let sessionID: String
    @State private var image: NSImage?

    var body: some View {
        Button {
            store.run {
                if let url = await store.image(artifact, sessionID: sessionID) {
                    store.previewURL = url
                } else {
                    throw MacError.message("图片暂未能预览，可尝试下载。")
                }
            }
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                        Text(artifact.name).font(.caption).lineLimit(1)
                    }
                    .padding(12)
                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: artifact.path) {
            if let url = await store.image(artifact, sessionID: sessionID),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: 480
               ] as CFDictionary) {
                image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
        }
    }
}

/// Two-phase thinking & tool execution view with flat, lightweight hierarchy:
/// - Phase 1 (While actively running): Shows each round's thinking summary visibly, while folding tool calls into a compact summary bar.
/// - Phase 2 (After completion): Folds all intermediate rounds & tools into a single lightweight pill and delivers the final conclusion below.
@MainActor struct TurnProcessCard: View {
    let summary: TurnProcessSummary
    let isActivelyRunning: Bool
    let durationSeconds: Int?
    let forceExpanded: Bool
    @State private var completedExpanded = false
    @State private var toolsExpanded = false
    @State private var expandedToolIDs = Set<String>()

    var body: some View {
        if isActivelyRunning || forceExpanded {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if isActivelyRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(isActivelyRunning ? "正在思考与执行" + (durationSeconds.map { " · \($0) 秒" } ?? "") : summary.headerTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !summary.rounds.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.rounds.enumerated()), id: \.offset) { idx, round in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                Text(round)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                if !summary.toolRows.isEmpty {
                    toolFoldingSection
                }
            }
            .padding(10)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    completedExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: completedExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: summary.hasError ? "exclamationmark.triangle" : "clock")
                            .font(.caption)
                            .foregroundStyle(summary.hasError ? Color.orange : Color.secondary)
                        Text(summary.completedTitle(durationSeconds: durationSeconds))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(completedExpanded ? "收起" : "展开")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                if completedExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if !summary.rounds.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(summary.rounds.enumerated()), id: \.offset) { idx, round in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(idx + 1).")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                        Text(round)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        if !summary.toolRows.isEmpty {
                            toolFoldingSection
                        }
                    }
                    .padding(10)
                    .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var toolFoldingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toolsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(summary.foldedToolsTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if toolsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.toolRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if expandedToolIDs.contains(row.id) {
                                    expandedToolIDs.remove(row.id)
                                } else {
                                    expandedToolIDs.insert(row.id)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: row.icon)
                                        .font(.caption)
                                        .foregroundStyle(row.isError ? Color.orange : Color.secondary)
                                        .frame(width: 16)
                                    Text(row.action)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(row.target)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(row.status)
                                        .font(.caption2)
                                        .foregroundStyle(row.isError ? Color.orange : Color.secondary)
                                    Image(systemName: expandedToolIDs.contains(row.id) ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            if expandedToolIDs.contains(row.id), !row.details.isEmpty {
                                Text(row.details)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(18)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .padding(.leading, 6)
            }
        }
    }
}

/// Flat code block component without nested vertical ScrollViews or multi-layer clipShapes.
@MainActor struct CodeBlock: View {
    let text: String, language: String
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NativeFiles.paste(text)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName:"doc.on.doc")
                            .font(.system(size: 10))
                        Text("复制")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle().fill(AppTheme.border).frame(height: 1)

            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor struct ArtifactView: View {
    @EnvironmentObject var store: MacStore
    let artifact: ArtifactReference, sessionID: String
    @State private var image: NSImage?
    var body: some View {
        HStack(spacing:12) {
            if artifact.image {
                Button {
                    store.run {
                        if let url = await store.image(artifact,sessionID:sessionID) {
                            store.previewURL = url
                        } else {
                            throw MacError.message("图片暂未能预览，可尝试下载。")
                        }
                    }
                } label: {
                    Group {
                        if let image {
                            Image(nsImage:image).resizable().scaledToFit()
                        } else {
                            Image(systemName:"photo").font(.title)
                        }
                    }
                    .frame(width:72,height:54)
                }
                .buttonStyle(.plain)
                .task(id:artifact.path) {
                    if let url = await store.image(artifact,sessionID:sessionID),
                       let source = CGImageSourceCreateWithURL(url as CFURL,nil),
                       let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:240] as CFDictionary) {
                        image = NSImage(cgImage:cg,size:NSSize(width:CGFloat(cg.width),height:CGFloat(cg.height)))
                    }
                }
            } else {
                Image(systemName:"doc").font(.title3).frame(width:24)
            }
            VStack(alignment:.leading,spacing:2) {
                Text(artifact.name).font(.callout).lineLimit(1)
                if artifact.image { Text("点按放大预览").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Button { store.run { try await store.download(artifact,sessionID:sessionID) } } label: { Image(systemName:"arrow.down.circle") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(AppTheme.elevatedBg, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// AppKit NSScrollView bridge that scrolls reliably to the true bottom without blank flashes
/// and updates `TranscriptScrollModel.following` without invalidating `ChatView.body`.
@MainActor struct TranscriptScrollBridge: NSViewRepresentable {
    let scrollModel: TranscriptScrollModel
    let sessionID: String
    let messageCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(scrollModel: scrollModel) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.bindScrollModel(scrollModel)
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded()
            context.coordinator.scrollToBottomWithRetry()
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bindScrollModel(scrollModel)
        context.coordinator.attachIfNeeded()
        if context.coordinator.lastSessionID != sessionID {
            context.coordinator.lastSessionID = sessionID
            context.coordinator.lastMessageCount = messageCount
            context.coordinator.scrollToBottomWithRetry()
            return
        }
        if context.coordinator.lastMessageCount != messageCount {
            context.coordinator.lastMessageCount = messageCount
            if scrollModel.following {
                context.coordinator.scrollToBottomOnce()
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?
        var scrollModel: TranscriptScrollModel
        var lastSessionID = ""
        var lastMessageCount = 0
        private var isProgrammaticScroll = false

        init(scrollModel: TranscriptScrollModel) {
            self.scrollModel = scrollModel
        }

        func bindScrollModel(_ model: TranscriptScrollModel) {
            self.scrollModel = model
            model.onScrollToBottomImmediate = { [weak self] in
                self?.scrollToBottomOnce()
            }
            model.onScrollToBottomSettled = { [weak self] in
                self?.scrollToBottomWithRetry()
            }
        }

        func attachIfNeeded() {
            guard let scroll = view?.enclosingScrollView, observedScrollView !== scroll else { return }
            stop()
            observedScrollView = scroll
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scroll,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleLiveScroll()
                }
            }
        }

        private func handleLiveScroll() {
            guard !isProgrammaticScroll,
                  let scroll = observedScrollView,
                  let document = scroll.documentView else { return }
            let distance = document.isFlipped
                ? (document.bounds.height - scroll.contentView.bounds.maxY)
                : scroll.contentView.bounds.minY
            let nearBottom = distance < 28
            if scrollModel.following != nearBottom {
                scrollModel.following = nearBottom
            }
        }

        func scrollToBottomWithRetry() {
            scrollToBottomOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                self?.scrollToBottomOnce()
            }
        }

        func scrollToBottomOnce() {
            attachIfNeeded()
            guard let scroll = view?.enclosingScrollView, let document = scroll.documentView else { return }
            isProgrammaticScroll = true
            defer { isProgrammaticScroll = false }
            let clip = scroll.contentView
            let targetY = document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
            clip.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(clip)
        }

        func stop() {
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
            }
            liveScrollObserver = nil
            observedScrollView = nil
        }
    }
}
#endif
