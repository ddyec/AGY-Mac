#if os(macOS)
import SwiftUI
import AGYMacCore

@MainActor struct TaskOptionsView: View {
    @EnvironmentObject var store: MacStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = TaskSettings()
    private var family: ModelFamily? { store.engine.families.first { $0.id == value.model } }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("模型与任务配置").font(.title2.weight(.semibold)); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
            Form {
                Section("模型") {
                    Picker("模型",selection:$value.model) { ForEach(store.engine.families) { Text($0.name).tag($0.id) } }
                        .onChange(of:value.model) { _ in if let family, !family.efforts.contains(value.effort) { value.effort = family.defaultEffort } }
                    Picker("思考强度",selection:$value.effort) { ForEach(family?.efforts ?? [],id:\.self) { Text(FileRules.effort($0)).tag($0) } }
                }
                Section("任务方式") {
                    Picker("审批策略",selection:$value.approvalMode) { Text("Restriction · 逐项审批").tag("review"); Text("Turbo · 自动执行").tag("turbo") }
                    Text(value.approvalMode == "review" ? "每次工具操作都等待你允许或拒绝。":"无需逐项确认即可操作文件和运行命令，仍遵守服务器明确禁止的规则。").font(.caption).foregroundStyle(.secondary)
                    Picker("执行方式",selection:$value.mode) { Text("先做计划").tag("plan"); Text("直接实施").tag("accept-edits") }
                }
                Section("项目") {
                    Text(URL(fileURLWithPath:value.workspace).lastPathComponent).font(.headline)
                    DisclosureGroup("手动指定服务器项目（高级）") { TextField("项目目录",text:$value.workspace).textFieldStyle(.roundedBorder); Text("更换已有会话的项目时，会保留原会话并开始新对话。").font(.caption).foregroundStyle(.secondary) }
                }
            }.formStyle(.grouped)
            HStack { Button("刷新可用模型") { store.run { try await store.engine.refreshModels() } }; Spacer(); Button("保存") { store.run { try await store.engine.configure(value); dismiss() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy || family == nil) }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(22).frame(width:560,height:570).onAppear { value = store.engine.settings }
    }
}
@MainActor struct PreferencesView: View {
    @EnvironmentObject var store: MacStore
    @State private var network = false
    @State private var tasks = false
    @State private var project = false
    @State private var disconnect = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                GroupBox("模型与任务") { VStack(alignment:.leading,spacing:12) {
                    LabeledContent("模型",value:store.engine.families.first { $0.id == store.engine.settings.model }?.name ?? "尚未连接")
                    LabeledContent("思考强度",value:FileRules.effort(store.engine.settings.effort))
                    Button("调整模型、审批和执行方式…") { tasks = true }.disabled(!store.connected)
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading) }
                GroupBox("工作项目") { HStack { VStack(alignment:.leading,spacing:6) { Text(store.connected ? URL(fileURLWithPath:store.engine.settings.workspace).lastPathComponent:"连接后可选择项目"); Text("文件、引用与会话共用当前项目。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("浏览并选择…") { project = true }.disabled(!store.connected || store.engine.selected?.running == true) }.padding(10) }
                GroupBox("外观与阅读") { VStack(spacing:14) {
                    Picker("界面主题",selection:Binding(get:{store.engine.profile.theme},set:{store.preferences(theme:$0)})) { Text("跟随 macOS").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                    Picker("回复展示",selection:Binding(get:{store.engine.profile.presentation},set:{store.preferences(presentation:$0)})) { Text("原版 · 完整过程").tag("原版"); Text("思考摘要 · 工具折叠").tag("步骤摘要"); Text("结论优先").tag("结论优先") }
                }.padding(10).disabled(!store.connected) }
                GroupBox("连接") { HStack { VStack(alignment:.leading,spacing:6) { Text(store.engine.connectionLabel); Text("密钥保存在钥匙串，账号与草稿按服务器账号隔离。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("网络设置…") { network = true }; if store.connected { Button("断开连接") { disconnect = true } } }.padding(10) }
                if store.connected { QuotaView() }
                Text("AGY · Mac 1.0 beta · Intel x86_64 · macOS 13+").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:820,alignment:.leading).padding(24).frame(maxWidth:.infinity)
        }
        .preferredColorScheme(store.colorScheme)
        .sheet(isPresented:$network) { NetworkView().environmentObject(store) }
        .sheet(isPresented:$tasks) { TaskOptionsView().environmentObject(store) }
        .sheet(isPresented:$project) { FilesView(picking:true,project:true).environmentObject(store).frame(width:700,height:600).padding(20) }
        .confirmationDialog("断开此电脑的连接？保存的草稿、队列和服务器任务会保留。",isPresented:$disconnect,titleVisibility:.visible) { Button("断开连接",role:.destructive) { store.run { try await store.disconnect() } } }
    }
}
@MainActor struct NetworkView: View {
    @EnvironmentObject var store: MacStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = NetworkSettings()
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("网络设置").font(.title2.weight(.semibold)); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
            Form {
                Section("加密 DNS") {
                    Toggle("启用 DNS over HTTPS",isOn:$value.encryptedDNS)
                    Picker("DoH 服务",selection:$value.provider) { ForEach(["Cloudflare","Google","AliDNS","DNSPod"],id:\.self) { Text($0).tag($0) } }.disabled(!value.encryptedDNS)
                    TextField("自定义 RFC 8484 DoH 地址（可留空，优先于预设）",text:$value.customDNS).disabled(!value.encryptedDNS)
                    Text("使用 macOS 原生加密 DNS。系统已有的加密解析器或 Private Relay 可能优先；没有时使用这里指定的 DoH。开启后不静默降级为明文 DNS；连接失败时可关闭此选项。").font(.caption).foregroundStyle(.secondary)
                }
                Section("代理") {
                    TextField("留空跟随系统；direct 表示直连",text:$value.proxy)
                    Text("支持 http://127.0.0.1:7890 或 socks5://127.0.0.1:7891。代理可能自行解析目标域名。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button(store.connected ? "保存并重新连接":"保存") { store.run { try await store.applyNetwork(value); dismiss() } }.buttonStyle(.borderedProminent).disabled(store.busy) }
        }.padding(22).frame(width:560,height:500).onAppear { value = store.engine.state.network }
    }
}
@MainActor struct QuotaView: View {
    @EnvironmentObject var store: MacStore
    var body: some View {
        GroupBox {
            VStack(alignment:.leading,spacing:16) {
                HStack { Text("账号用量").font(.headline); Spacer(); Button("刷新") { refresh() }.disabled(store.busy) }
                if let limits = store.limits {
                    ForEach(limits.groups) { group in VStack(alignment:.leading,spacing:10) {
                        Text(group.name).font(.subheadline.weight(.medium))
                        if let description = group.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        ForEach(group.buckets) { bucket in VStack(alignment:.leading,spacing:5) {
                            HStack { Text(bucket.window == "weekly" ? "每周额度":bucket.window == "5h" ? "5 小时额度":bucket.name); Spacer(); Text(bucket.remaining.map { "\(Int($0*100))% 可用" } ?? "服务器未提供") }.font(.caption)
                            if let value = bucket.remaining { ProgressView(value:value,total:1).tint(value < 0.15 ? .orange:.accentColor) }
                            if let raw = bucket.reset_time { Text("重置：" + raw).font(.caption2).foregroundStyle(.secondary) }
                        } }
                    } }
                    Text("来源：" + limits.source).font(.caption2).foregroundStyle(.secondary)
                } else { Text("刷新后显示服务器提供的真实额度。").foregroundStyle(.secondary) }
            }.padding(10)
        }.task { if store.limits == nil { refresh() } }
    }
    private func refresh() { store.run { store.limits = try await store.engine.limits() } }
}
#endif
