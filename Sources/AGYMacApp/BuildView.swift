#if os(macOS)
import SwiftUI
import AGYMacCore

@MainActor struct BuildView: View {
    @EnvironmentObject var store: MacStore
    @ObservedObject var local: LocalBuild
    @ObservedObject var worker: HybridWorker
    @State private var target = "local"
    @State private var confirm = false
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                GroupBox {
                    VStack(alignment:.leading,spacing:14) {
                        Label("由 AI 自动选择构建环境",systemImage:"sparkles").font(.title2.weight(.semibold))
                        Text("直接在对话里提出任务。AI 会探测当前项目和在线设备：网页与 Linux 任务在服务器运行，需要 Apple 工具链的任务自动交给这台 Intel Mac。").foregroundStyle(.secondary)
                        Toggle("允许 AI 在这台 Mac 上构建",isOn:Binding(get:{store.engine.profile.aiBuildsEnabled != false},set:{ enabled in store.run { try store.engine.setAIBuilds(enabled); if !enabled { worker.stop() } else if let sid = store.engine.selected?.id { try await worker.prepare(sid,store:store) } } }))
                        Label(worker.status,systemImage:worker.executing ? "gearshape.2":"desktopcomputer").foregroundStyle(.secondary)
                        if !worker.tools.isEmpty { Text("已探测工具："+worker.tools.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                        if !worker.localOutputs.isEmpty {
                            HStack(spacing:10) {
                                Image(systemName:"checkmark.seal.fill").foregroundStyle(.green)
                                Text("最新本机产物（\(worker.localOutputs.map(\.lastPathComponent).joined(separator:"、"))）已直接保存在本机 ~/Downloads/AGY-Builds").font(.caption)
                                Spacer()
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(worker.localOutputs) }.controlSize(.small)
                            }.padding(8).background(Color.green.opacity(0.08),in:RoundedRectangle(cornerRadius:8))
                        }
                        Text("源码自动同步到本机新副本；构建产物直接保存在本机 ~/Downloads/AGY-Builds，无需从服务器重复下载。Restriction 模式按策略审批，Turbo 模式直接执行。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                }
                DisclosureGroup("高级：手动执行与诊断") { VStack(alignment:.leading,spacing:20) {
                GroupBox("执行位置") { VStack(alignment:.leading,spacing:14) {
                    Picker("目标",selection:$target) { Text("本机 · Intel Mac").tag("local"); Text("服务器 · 网页 / 服务端").tag("server") }.pickerStyle(.segmented)
                    if target == "local" {
                        HStack { TextField("本机项目目录",text:$local.folder).textFieldStyle(.roundedBorder); Button("选择…") { if let url = NativeFiles.chooseFolder() { local.folder = url.path } } }
                        Button("同步当前服务器项目到新的本机副本") { store.run { try await local.synchronize(store) } }.disabled(store.engine.status?.capabilities.projectSnapshots != true)
                    } else { Label(URL(fileURLWithPath:store.engine.settings.workspace).lastPathComponent,systemImage:"folder") }
                }.padding(12) }.disabled(local.running || store.busy)
                GroupBox("构建命令") { VStack(alignment:.leading,spacing:12) {
                    TextEditor(text:$local.command).font(.system(.body,design:.monospaced)).frame(height:100).scrollContentBackground(.hidden).padding(8).background(Color.secondary.opacity(0.05),in:RoundedRectangle(cornerRadius:8)).disabled(local.running)
                    HStack {
                        Button { confirm = true } label: { Label("执行这一次",systemImage:"play.fill") }.buttonStyle(.borderedProminent).disabled(local.running || store.busy || local.command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        if local.running { Button("停止本机命令",role:.destructive) { local.stop() } }
                        Spacer(); Button("回传日志") { store.run { try await local.uploadLog(store) } }.disabled(local.running)
                        Button("回传产物…") { store.run { try await store.upload(reference:false) } }
                    }
                }.padding(12) }
                if !local.log.isEmpty { GroupBox("本机输出") { ScrollView([.horizontal,.vertical]) { Text(local.log).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12) }.frame(height:300) } }
                Text("此区域用于手动诊断；对话中的 AI 自动构建无需点击这里。").font(.caption).foregroundStyle(.secondary)
                } }
            }.frame(maxWidth:900).padding(24).frame(maxWidth:.infinity)
        }.confirmationDialog(target == "local" ? "在这台 Intel Mac 上执行？":"交给当前服务器 AGY 执行？",isPresented:$confirm,titleVisibility:.visible) {
            Button("执行这一次") { start() }; Button("取消",role:.cancel) {}
        } message: { Text((target == "local" ? local.folder:store.engine.settings.workspace) + "\n\n" + local.command) }
        .onAppear { if !loaded, !local.running, local.folder.isEmpty, local.command.isEmpty, let saved = store.engine.profile.build { target = saved.target; local.folder = saved.folder; local.command = saved.command }; loaded = true }
    }
    private func start() {
        store.run {
            try store.engine.rememberBuild(BuildPlan(target:target,folder:local.folder,command:local.command))
            if target == "local" { try local.start() }
            else {
                guard store.engine.draft.text.isEmpty, store.engine.draft.references.isEmpty else { throw MacError.message("请先处理当前聊天草稿，再发送服务器构建请求。") }
                try store.engine.updateDraft("请在当前服务器项目执行以下构建命令，报告退出码、日志与产物，遵守当前审批策略。\n```sh\n" + local.command + "\n```")
                try await store.engine.send(); store.page = .chat
            }
        }
    }
}
#endif
