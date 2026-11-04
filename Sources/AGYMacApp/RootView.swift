#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AGYMacCore

/// Unified, opaque 4-tier visual surface palette for macOS Dark & Light appearances.
/// Avoids mixing translucent materials (.regularMaterial) with flat backgrounds so all regions align cleanly.
@MainActor enum AppTheme {
    static let sidebarBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1.0)
            : NSColor(srgbRed: 0.945, green: 0.95, blue: 0.965, alpha: 1.0)
    })
    static let canvasBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.125, green: 0.13, blue: 0.15, alpha: 1.0)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.995, alpha: 1.0)
    })
    static let cardBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.195, alpha: 1.0)
            : NSColor(srgbRed: 0.955, green: 0.96, blue: 0.975, alpha: 1.0)
    })
    static let elevatedBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.195, green: 0.205, blue: 0.235, alpha: 1.0)
            : NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: 1.0)
    })
    static let userBubbleBg = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.21, blue: 0.27, alpha: 1.0)
            : NSColor(srgbRed: 0.91, green: 0.94, blue: 0.99, alpha: 1.0)
    })
    static let border = Color.primary.opacity(0.08)
    static let strongBorder = Color.primary.opacity(0.14)
}

@MainActor enum Brand {
    static var image: NSImage? { Bundle.main.url(forResource:"Mark",withExtension:"png").flatMap(NSImage.init(contentsOf:)) }
}

@MainActor struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View {
        Group {
            if let image = Brand.image {
                Image(nsImage:image).resizable().scaledToFit()
            } else {
                Image(systemName:"sparkles").resizable().scaledToFit().foregroundStyle(.blue)
            }
        }
        .frame(width:size,height:size)
    }
}

@MainActor struct RootView: View {
    @EnvironmentObject var store: MacStore
    @State private var search = ""
    @State private var renaming: Session?
    @State private var title = ""
    @State private var deleting: Session?

    private var filteredSessions: [Session] {
        store.engine.sessions.filter { search.isEmpty || $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        Group {
            if store.connected {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 248)
                        .frame(maxHeight: .infinity)
                        .background(AppTheme.sidebarBg)

                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(width: 1)
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        headerBar
                        Rectangle()
                            .fill(AppTheme.border)
                            .frame(height: 1)
                        if let error = store.error { NoticeBanner(text:error) { store.error = nil } }
                        if let warning = store.engine.streamError { NoticeBanner(text:warning) {} }
                        Group {
                            switch store.page {
                            case .chat: ChatView()
                            case .files: FilesView(picking:false,project:false)
                            case .builds: BuildView(local:store.localBuild,worker:store.hybridWorker)
                            case .skills: SkillsView()
                            case .settings: PreferencesView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.canvasBg)
                }
                .ignoresSafeArea(.container, edges: .top)
            } else {
                ConnectionView()
                    .background(AppTheme.canvasBg)
            }
        }
        .preferredColorScheme(store.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in store.localBuild.stop() }
        .sheet(isPresented:$store.showTaskOptions) { TaskOptionsView().environmentObject(store) }
        .sheet(isPresented:$store.showReferences) { FilesView(picking:true,project:store.choosingProject).environmentObject(store).frame(minWidth:680,minHeight:560).padding(20) }
        .sheet(isPresented:Binding(get:{store.previewURL != nil},set:{if !$0 {store.previewURL = nil}})) { if let url = store.previewURL { ImagePreview(url:url).frame(minWidth:640,minHeight:500) } }
        .alert("重命名对话",isPresented:Binding(get:{renaming != nil},set:{if !$0 {renaming = nil}})) {
            TextField("名称",text:$title)
            Button("保存") { if let value = renaming { store.run { try await store.engine.rename(value,to:title) } }; renaming = nil }
            Button("取消",role:.cancel) { renaming = nil }
        }
        .confirmationDialog("删除这条会话记录？项目文件会保留。",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting = nil}}),titleVisibility:.visible) {
            Button("删除记录",role:.destructive) { if let value = deleting { store.run { try await store.engine.delete(value) } }; deleting = nil }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text(store.page == .chat ? (store.engine.selected?.title ?? "新对话") : store.page.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)

            if store.busy {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 12)

            if store.page == .chat {
                Button {
                    store.showTaskOptions = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: store.engine.settings.approvalMode == "turbo" ? "bolt.fill" : "checkmark.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(store.engine.settings.approvalMode == "turbo" ? Color.orange : Color.accentColor)
                        Text(store.engine.settings.approvalMode == "turbo" ? "Turbo 自动执行" : "Restriction 审批")
                            .font(.system(size: 12, weight: .medium))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(store.engine.settings.mode == "plan" ? "先做计划" : "直接实施")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("点击调整执行模式与策略")
            }

            Button {
                store.chooseProject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(URL(fileURLWithPath: store.engine.settings.workspace).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("切换工作项目")

            if store.page == .chat {
                Button {
                    store.showTaskOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 26)
                        .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("模型与任务配置")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top bar with room for macOS traffic lights
            HStack(spacing: 9) {
                BrandMark(size: 24)
                Text("AGY")
                    .font(.system(size: 16, weight: .bold))
                Text("Mac")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppTheme.elevatedBg, in: Capsule())
                Spacer()
            }
            .padding(.top, 38)
            .padding(.horizontal, 4)

            // Primary New Conversation Button (flush aligned with all sidebar items)
            Button {
                store.run { try await store.newConversation() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    Text("新建对话")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.busy)

            // Navigation items
            VStack(spacing: 3) {
                ForEach(Page.allCases) { page in
                    let active = store.page == page
                    Button {
                        store.page = page
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.icon)
                                .font(.system(size: 13, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                            Text(page.title)
                                .font(.system(size: 13, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.85))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            active ? AppTheme.elevatedBg : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(active ? AppTheme.border : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
                .padding(.vertical, 2)

            // Recent Conversations header
            HStack {
                Text("最近对话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.run { try await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("刷新会话")
            }
            .padding(.horizontal, 4)

            // Custom flush-aligned search box (replaces misaligned .roundedBorder TextField)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索对话", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 1))

            // Flush-aligned session list (replaces inset List that caused margin mismatch)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filteredSessions) { session in
                        let selected = store.engine.selected?.id == session.id && store.page == .chat
                        Button {
                            store.select(session)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: session.running ? "circle.dotted" : "bubble.left")
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.running ? Color.orange : (selected ? Color.accentColor : Color.secondary))
                                    .frame(width: 16)
                                Text(session.title)
                                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                selected ? AppTheme.elevatedBg : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? AppTheme.border : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("打开") { store.select(session) }
                            Button("重命名…") { title = session.title; renaming = session }
                            Divider()
                            Button("删除记录…", role: .destructive) { deleting = session }
                        }
                        .help(session.title)
                    }
                }
                .padding(.vertical, 2)
            }

            // Bottom status bar (flush aligned)
            HStack(spacing: 8) {
                Circle()
                    .fill(store.engine.selected?.running == true ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(store.captureEnabled ? "离线界面预览 · 示例数据" : store.engine.connectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Intel")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

@MainActor struct NoticeBanner: View {
    let text: String; let close: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.cardBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
        }
    }
}

@MainActor struct ConnectionView: View {
    @EnvironmentObject var store: MacStore
    @State private var address = "https://agy.yectech.uk"
    @State private var key = ""
    @State private var reveal = false
    @State private var network = false
    var body: some View {
        VStack(spacing:22) {
            BrandMark(size:58)
            VStack(spacing:8) {
                Text("在 Mac 上继续工作。").font(.largeTitle.weight(.semibold))
                Text("连接你的 AGY 服务器，共用会话、工作文件和产物。").foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:14) {
                Text("服务器地址").font(.caption).foregroundStyle(.secondary)
                TextField("https://你的服务器",text:$address).textFieldStyle(.roundedBorder)
                Text("连接密钥").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Group {
                        if reveal { TextField("手机与电脑共用的连接密钥",text:$key) }
                        else { SecureField("手机与电脑共用的连接密钥",text:$key) }
                    }.textFieldStyle(.roundedBorder)
                    Button { reveal.toggle() } label: { Image(systemName:reveal ? "eye.slash":"eye") }.buttonStyle(.plain)
                }
                Button {
                    store.run { try await store.connect(address:address,token:key); key = "" }
                } label: {
                    HStack {
                        Spacer()
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.busy ? "正在连接…":"连接 AGY")
                        Spacer()
                    }.padding(.vertical,5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || !store.storageReady)
                .keyboardShortcut(.return,modifiers:[])
            }
            .padding(24)
            .background(AppTheme.cardBg, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border, lineWidth: 1))

            Button("网络设置 · DoH 与代理") { network = true }.buttonStyle(.link)
            if let error = store.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Text("连接密钥保存在 macOS 钥匙串。Google 账号由服务器上的 AGY 管理。").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth:470)
        .padding(40)
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .sheet(isPresented:$network) { NetworkView().environmentObject(store) }
    }
}

@MainActor struct ImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    var body: some View {
        VStack {
            HStack {
                Text(url.lastPathComponent).lineLimit(1)
                Spacer()
                Button { zoom = max(0.25,zoom-0.25) } label: { Image(systemName:"minus.magnifyingglass") }
                Text("\(Int(zoom*100))%").monospacedDigit()
                Button { zoom = min(5,zoom+0.25) } label: { Image(systemName:"plus.magnifyingglass") }
                Button("完成") { dismiss() }
            }
            GeometryReader { geometry in
                ScrollView([.horizontal,.vertical]) {
                    if let image = NSImage(contentsOf:url) {
                        Image(nsImage:image)
                            .resizable()
                            .scaledToFit()
                            .frame(width:max(100,geometry.size.width*zoom),height:max(100,geometry.size.height*zoom))
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.canvasBg)
    }
}
#endif
