#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AGYMacCore

@MainActor enum Brand {
    static var image: NSImage? { Bundle.main.url(forResource:"Mark",withExtension:"png").flatMap(NSImage.init(contentsOf:)) }
}
@MainActor struct BrandMark: View {
    var size: CGFloat = 32
    var body: some View { Group { if let image = Brand.image { Image(nsImage:image).resizable().scaledToFit() } else { Image(systemName:"sparkles").resizable().scaledToFit().foregroundStyle(.blue) } }.frame(width:size,height:size) }
}
@MainActor struct RootView: View {
    @EnvironmentObject var store: MacStore
    @State private var search = ""
    @State private var renaming: Session?
    @State private var title = ""
    @State private var deleting: Session?
    var body: some View {
        Group {
            if store.connected {
                HSplitView {
                    sidebar.frame(minWidth:228,idealWidth:248,maxWidth:280,maxHeight:.infinity)
                        .background(Color(nsColor:.windowBackgroundColor))
                    VStack(spacing:0) {
                        HStack(spacing:12) {
                            Text(store.page == .chat ? store.engine.selected?.title ?? "新对话":store.page.title).font(.title3.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if store.busy { ProgressView().controlSize(.small) }
                            Button { store.chooseProject() } label: { Label(URL(fileURLWithPath:store.engine.settings.workspace).lastPathComponent,systemImage:"folder") }.controlSize(.small).help("切换工作项目")
                            if store.page == .chat { Button { store.showTaskOptions = true } label: { Image(systemName:"slider.horizontal.3") }.controlSize(.small).help("模型与任务配置") }
                        }.padding(.horizontal,24).padding(.vertical,14)
                        Divider()
                        if let error = store.error { NoticeBanner(text:error) { store.error = nil } }
                        if let warning = store.engine.streamError { NoticeBanner(text:warning) {} }
                        switch store.page {
                        case .chat: ChatView()
                        case .files: FilesView(picking:false,project:false)
                        case .builds: BuildView(local:store.localBuild)
                        case .skills: SkillsView()
                        case .settings: PreferencesView()
                        }
                    }.frame(minWidth:500,maxWidth:.infinity,maxHeight:.infinity)
                        .background(Color(nsColor:.textBackgroundColor))
                }
            } else { ConnectionView() }
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
    private var sidebar: some View {
        VStack(spacing:14) {
            HStack(spacing:10) { BrandMark(); Text("AGY").font(.title2.weight(.semibold)); Spacer(); Text("Mac").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal,8).padding(.top,16)
            Button { store.run { try await store.newConversation() } } label: { HStack { Image(systemName:"plus"); Text("新建对话"); Spacer(); Text("⌘N").foregroundStyle(.secondary) }.padding(.vertical,7) }.buttonStyle(.bordered).disabled(store.busy)
            VStack(spacing:4) {
                ForEach(Page.allCases) { page in
                    Button { store.page = page } label: {
                        HStack(spacing:10) { Image(systemName:page.icon).frame(width:20); Text(page.title).lineLimit(1); Spacer() }
                            .font(.system(size:13,weight:store.page == page ? .semibold:.regular)).padding(.horizontal,12).padding(.vertical,9)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).background(store.page == page ? Color.accentColor.opacity(0.13):Color.clear,in:RoundedRectangle(cornerRadius:9))
                }
            }
            HStack { Text("最近对话").font(.caption.weight(.medium)).foregroundStyle(.secondary); Spacer(); Button { store.run { try await store.reload() } } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(.plain).help("刷新会话") }
            TextField("搜索对话",text:$search).textFieldStyle(.roundedBorder)
            List(selection:Binding(get:{store.engine.selected?.id},set:{ id in if let id, let session = store.engine.sessions.first(where:{$0.id == id}) { store.select(session) } })) {
                ForEach(store.engine.sessions.filter { search.isEmpty || $0.title.localizedStandardContains(search) }) { session in
                    HStack { Image(systemName:session.running ? "circle.dotted":"bubble.left").foregroundStyle(.secondary); Text(session.title).lineLimit(1); Spacer(minLength:0) }.padding(.vertical,5).tag(session.id)
                        .contextMenu { Button("打开") { store.select(session) }; Button("重命名…") { title = session.title; renaming = session }; Button("删除记录…",role:.destructive) { deleting = session } }
                        .help(session.title)
                }
            }.listStyle(.inset).scrollContentBackground(.hidden).disabled(store.busy)
            HStack { Circle().fill(store.engine.selected?.running == true ? Color.orange:Color.green).frame(width:7,height:7); Text(store.captureEnabled ? "离线界面预览 · 示例数据":store.engine.connectionLabel).font(.caption); Spacer(); Text("Intel").font(.caption2).foregroundStyle(.secondary) }.padding(10).background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
        }.padding(.horizontal,14).padding(.bottom,12)
    }
}
@MainActor struct NoticeBanner: View {
    let text: String; let close: () -> Void
    var body: some View { HStack(alignment:.top) { Image(systemName:"exclamationmark.circle").foregroundStyle(.orange); Text(text).font(.callout).textSelection(.enabled); Spacer(); Button(action:close) { Image(systemName:"xmark") }.buttonStyle(.plain) }.padding(12).background(Color.orange.opacity(0.09)) }
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
            VStack(spacing:8) { Text("在 Mac 上继续工作。").font(.largeTitle.weight(.semibold)); Text("连接你的 AGY 服务器，共用会话、工作文件和产物。").foregroundStyle(.secondary) }
            VStack(alignment:.leading,spacing:14) {
                Text("服务器地址").font(.caption).foregroundStyle(.secondary)
                TextField("https://你的服务器",text:$address).textFieldStyle(.roundedBorder)
                Text("连接密钥").font(.caption).foregroundStyle(.secondary)
                HStack { Group { if reveal { TextField("手机与电脑共用的连接密钥",text:$key) } else { SecureField("手机与电脑共用的连接密钥",text:$key) } }.textFieldStyle(.roundedBorder); Button { reveal.toggle() } label: { Image(systemName:reveal ? "eye.slash":"eye") }.buttonStyle(.plain) }
                Button { store.run { try await store.connect(address:address,token:key); key = "" } } label: { HStack { Spacer(); if store.busy { ProgressView().controlSize(.small) }; Text(store.busy ? "正在连接…":"连接 AGY"); Spacer() }.padding(.vertical,5) }.buttonStyle(.borderedProminent).disabled(store.busy || !store.storageReady).keyboardShortcut(.return,modifiers:[])
            }.padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:20))
            Button("网络设置 · DoH 与代理") { network = true }.buttonStyle(.link)
            if let error = store.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Text("连接密钥保存在 macOS 钥匙串。Google 账号由服务器上的 AGY 管理。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:470).padding(40).frame(maxWidth:.infinity,maxHeight:.infinity)
            .sheet(isPresented:$network) { NetworkView().environmentObject(store) }
    }
}
@MainActor struct ImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    var body: some View { VStack {
        HStack { Text(url.lastPathComponent).lineLimit(1); Spacer(); Button { zoom = max(0.25,zoom-0.25) } label: { Image(systemName:"minus.magnifyingglass") }; Text("\(Int(zoom*100))%").monospacedDigit(); Button { zoom = min(5,zoom+0.25) } label: { Image(systemName:"plus.magnifyingglass") }; Button("完成") { dismiss() } }
        GeometryReader { geometry in ScrollView([.horizontal,.vertical]) { if let image = NSImage(contentsOf:url) { Image(nsImage:image).resizable().scaledToFit().frame(width:max(100,geometry.size.width*zoom),height:max(100,geometry.size.height*zoom)) } } }
    }.padding(16) }
}
#endif
