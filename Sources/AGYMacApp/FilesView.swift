#if os(macOS)
import SwiftUI
import AppKit
import AGYMacCore

@MainActor struct FilesView: View {
    @EnvironmentObject var store: MacStore
    @Environment(\.dismiss) private var dismiss
    let picking: Bool, project: Bool
    @State private var scope = "workspace", path = "", search = "", hidden = false, recent = false
    @State private var listing: FileListing?, selection: String?, loading = false, failure: String?
    @State private var loadID = UUID()
    @State private var loadTask: Task<Void,Never>?
    private var selected: FileEntry? { listing?.entries.first { $0.id == selection } }
    private var entries: [FileEntry] {
        (listing?.entries ?? []).filter { (!project || $0.directory) && (hidden || !$0.name.hasPrefix(".")) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
            .sorted { a,b in if a.directory != b.directory { return a.directory }; return recent && a.modified != b.modified ? a.modified > b.modified:a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text(project ? "选择项目":picking ? "引用工作文件":"文件与产物").font(.title2.weight(.semibold)); Spacer(); if loading { ProgressView().controlSize(.small) }; if picking { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) } }
            HStack {
                Button { path = ""; reload() } label: { Image(systemName:"house") }.help("项目根目录")
                Button { path = path.split(separator:"/").dropLast().joined(separator:"/"); reload() } label: { Image(systemName:"chevron.up") }.disabled(path.isEmpty)
                if !project { Picker("位置",selection:$scope) { Text("工作区").tag("workspace"); Text("已上传").tag("uploads"); Text("AGY 产物").tag("artifacts") }.labelsHidden().frame(width:160).onChange(of:scope) { _ in path = ""; reload() } }
                Text(path.isEmpty ? "当前项目":path + "/").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle); Spacer()
                Button { reload() } label: { Image(systemName:"arrow.clockwise") }
            }
            HStack { TextField("搜索当前文件夹",text:$search).textFieldStyle(.roundedBorder); Toggle("隐藏文件",isOn:$hidden).toggleStyle(.checkbox); Toggle("最近修改",isOn:$recent).toggleStyle(.checkbox) }.font(.caption)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            List(selection:$selection) {
                ForEach(entries) { item in
                    HStack(spacing:12) {
                        Image(systemName:item.directory ? "folder.fill":"doc").font(.title3).foregroundStyle(item.directory ? Color.accentColor:Color.secondary).frame(width:26)
                        VStack(alignment:.leading,spacing:3) { Text(item.name).lineLimit(1); Text(item.directory ? "文件夹 · 可整体引用":ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); if item.modified > 0 { Text(Date(timeIntervalSince1970:item.modified),style:.date).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical,6).contentShape(Rectangle()).tag(item.id)
                        .onTapGesture(count:2) { selection = item.id; if item.directory { enter(item) } }
                        .contextMenu {
                            if item.directory { Button("打开文件夹") { enter(item) } }
                            if !project { Button(item.directory ? "@ 整个文件夹":"@ 此文件") { reference(item) }; if !item.directory { Button("下载…") { download(item) } } }
                        }
                }
            }.listStyle(.inset).overlay { if !loading && entries.isEmpty { VStack(spacing:8) { Image(systemName:"folder").font(.largeTitle); Text(search.isEmpty ? "这个文件夹是空的":"没有匹配的文件") }.foregroundStyle(.secondary) } }
            HStack {
                if let selected { Text(selected.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) } else { Text("单击选中，双击打开文件夹").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if project { Button("使用此项目") { useProject() }.buttonStyle(.borderedProminent).disabled(listing == nil || loading) }
                else {
                    Button { store.run { try await store.upload(); await load() } } label: { Label("上传",systemImage:"arrow.up.doc") }
                    Button("下载…") { if let selected { download(selected) } }.disabled(selected == nil || selected?.directory == true)
                    Button("@ 选中项") { if let selected { reference(selected) } }.disabled(selected == nil)
                    Button("@ 此文件夹") { referenceCurrent() }.buttonStyle(.borderedProminent).disabled(listing == nil || listing?.root.isEmpty == true)
                }
            }.controlSize(.small).disabled(store.busy)
        }.padding(picking ? 0:24).task { await load() }.onDisappear { loadTask?.cancel() }
    }
    private func reload() { loadTask?.cancel(); loadTask = Task { await load() } }
    private func load() async {
        let id = UUID(); loadID = id; loading = true; failure = nil; selection = nil; listing = nil
        defer { if id == loadID { loading = false } }
        do {
            let root = project ? store.engine.status?.roots.first:nil
            let value = try await store.engine.browse(scope:scope,path:path,root:root)
            if !Task.isCancelled, loadID == id { listing = value }
        } catch { if !Task.isCancelled, loadID == id { failure = error.localizedDescription } }
    }
    private func enter(_ entry: FileEntry) { path = [path,entry.name].filter { !$0.isEmpty }.joined(separator:"/"); reload() }
    private func reference(_ entry: FileEntry) { store.run { try store.engine.addReference(FileReference(path:entry.path,label:FileRules.label(scope:scope,folder:path,name:entry.name,directory:entry.directory),directory:entry.directory)); store.page = .chat; if picking { dismiss() } } }
    private func referenceCurrent() {
        guard let listing else { return }
        let absolute = URL(fileURLWithPath:listing.root).appendingPathComponent(path).path
        store.run { try store.engine.addReference(FileReference(path:absolute,label:(path.isEmpty ? "当前项目":path) + "/",directory:true)); store.page = .chat; if picking { dismiss() } }
    }
    private func download(_ entry: FileEntry) { store.run { try await store.download(ArtifactReference(path:entry.path,name:entry.name,mime:"application/octet-stream")) } }
    private func useProject() {
        guard let listing else { return }; var next = store.engine.settings; next.workspace = URL(fileURLWithPath:listing.root).appendingPathComponent(path).path
        store.run { try await store.engine.configure(next); if picking { dismiss() } }
    }
}
#endif
