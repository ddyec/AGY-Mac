#if os(macOS)
import SwiftUI
import AGYMacCore

enum WorkflowCatalog {
    static let items: [Skill] = [
        Skill(name:"/plan · 先做计划",prompt:"/plan "), Skill(name:"/boost · 深度思考",prompt:"/boost "),
        Skill(name:"/goal · 目标推进",prompt:"/goal "), Skill(name:"/teamwork · 协同工作",prompt:"/teamwork "),
        Skill(name:"/grill-me · 对齐需求",prompt:"/grill-me "), Skill(name:"/learn · 沉淀经验",prompt:"/learn "),
        Skill(name:"/browser · 浏览网页",prompt:"/browser "), Skill(name:"/compact · 整理上下文",prompt:"/compact ")]
}
@MainActor struct SkillsView: View {
    @EnvironmentObject var store: MacStore
    @State private var adding = false
    @State private var name = ""
    @State private var prompt = ""
    @State private var file = ""
    @State private var discovered: [Skill] = []
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack { Text("快捷工作流与项目技能").font(.callout).foregroundStyle(.secondary); Spacer(); Button { adding = true } label: { Label("自定义技能",systemImage:"plus") } }
                Text("选择后插入输入框，由你确认发送。命令和技能的实际执行能力以服务器 AGY 为准。").font(.callout).foregroundStyle(.secondary)
                GroupBox("快捷工作流") { LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:10) {
                    ForEach(WorkflowCatalog.items) { skill in Button { apply(skill) } label: { HStack { Text(skill.name); Spacer(); Image(systemName:"arrow.up.left") }.padding(9) }.buttonStyle(.bordered) }
                }.padding(10) }
                GroupBox("项目技能") { VStack(alignment:.leading,spacing:12) {
                    Button("读取项目 .agents/skills 与 .agent/skills") { discover() }
                    if discovered.isEmpty { Text("浏览项目中的 SKILL.md，选中后作为文件引用发送。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(discovered) { skill in HStack { Image(systemName:"doc.text"); Text(skill.name); Spacer(); Button("引用") { apply(skill) } } }
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading) }
                GroupBox("自定义技能") { VStack(alignment:.leading,spacing:12) {
                    if store.engine.profile.skills.isEmpty { Text("把常用提示词或技能文件保存到当前服务器账号。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(store.engine.profile.skills) { skill in HStack { VStack(alignment:.leading,spacing:4) { Text(skill.name); Text(skill.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button("使用") { apply(skill) }; Button(role:.destructive) { store.run { try store.engine.removeSkill(skill.id) } } label: { Image(systemName:"trash") } } }
                }.padding(10).frame(maxWidth:.infinity,alignment:.leading) }
            }.frame(maxWidth:850).padding(24).frame(maxWidth:.infinity)
        }.sheet(isPresented:$adding) { VStack(alignment:.leading,spacing:14) {
            Text("保存技能").font(.title2.weight(.semibold)); TextField("名称",text:$name).textFieldStyle(.roundedBorder)
            TextEditor(text:$prompt).font(.body).frame(height:160).border(Color.secondary.opacity(0.2))
            TextField("可选：服务器上的 SKILL.md 路径",text:$file).textFieldStyle(.roundedBorder)
            HStack { Button("取消") { adding = false }; Spacer(); Button("保存") { store.run { try store.engine.saveSkill(Skill(name:name,prompt:prompt,path:file.isEmpty ? nil:file)); adding = false; name = ""; prompt = ""; file = "" } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespaces).isEmpty || prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(22).frame(width:500) }
    }
    private func apply(_ skill: Skill) {
        store.run {
            if let path = skill.path { try store.engine.addReference(FileReference(path:path,label:skill.name + "/SKILL.md",directory:false)) }
            store.insert(skill.prompt); store.page = .chat
        }
    }
    private func discover() {
        store.run {
            var found: [Skill] = []
            for directory in [".agents/skills",".agent/skills"] {
                do {
                    let listing = try await store.engine.browse(path:directory)
                    for entry in listing.entries.filter({$0.directory}).prefix(50) {
                        let nested = try await store.engine.browse(path:directory + "/" + entry.name)
                        if let file = nested.entries.first(where:{$0.name == "SKILL.md" && !$0.directory}) { found.append(Skill(name:entry.name,prompt:"请按引用的 SKILL.md 执行以下任务：\n",path:file.path)) }
                    }
                } catch let error as GatewayError where error.status == 403 || error.status == 404 { continue }
            }
            discovered = found
        }
    }
}
#endif
