#if os(macOS)
import SwiftUI
import AGYMacCore

@MainActor struct BuildView: View {
    @EnvironmentObject var store: MacStore
    @ObservedObject var local: LocalBuild
    @State private var target = "local"
    @State private var confirm = false
    @State private var loaded = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text("混合构建").font(.title2.weight(.semibold))
                Text("Mac 项目在这台 Intel Mac 上构建，网页与服务端任务留在服务器。").foregroundStyle(.secondary)
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
                Text("项目同步总是创建新副本。构建日志和产物只会在你点击回传时上传。").font(.caption).foregroundStyle(.secondary)
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
