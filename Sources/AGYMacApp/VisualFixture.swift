#if os(macOS)
import Foundation
import AGYMacCore

final class PreviewStorage: StateStorage {
    private var data: Data?
    func load() throws -> AppState { try data.map { try JSONDecoder().decode(AppState.self,from:$0) } ?? AppState() }
    func save(_ state: AppState) throws { data = try JSONEncoder().encode(state) }
}
/// Activated solely by --capture-ui. No keychain access, real host or mutation.
final class VisualFixture: URLProtocol {
    static let sessionID = "11111111-1111-4111-8111-111111111111"
    static var approvalScene = false
    static var png = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "preview.invalid", request.httpMethod == "GET" || HybridVerification.enabled else { client?.urlProtocol(self,didFailWithError:MacError.message("离线预览禁止真实网络和任务写入。")); return }
        do {
            if let (data,mime) = try HybridVerification.response(request) { respond(data,mime:mime); return }
            let path = request.url!.path
            var value: Any
            if path.hasSuffix("/status") { value = ["name":"离线界面预览","version":1,"roots":["/demo/AGY-Mac"],"defaultModel":"gemini-medium","accountProfile":"offline-preview","capabilities":["separateEffort":true,"nativeApprovals":true,"fileBrowser":true,"directoryMentions":true,"projectSnapshots":true,"aiHybridBuilds":true]] as [String:Any] }
            else if path.hasSuffix("/models") { value = ["models":[["id":"gemini-medium","name":"Gemini · 示例"]],"families":[["id":"gemini","name":"Gemini · 示例","variants":[["id":"gemini-low","effort":"low"],["id":"gemini-medium","effort":"medium"],["id":"gemini-high","effort":"high"]],"efforts":["low","medium","high"],"defaultEffort":"medium"],["id":"claude","name":"Claude · 示例","variants":[["id":"claude-high","effort":"high"]],"efforts":["high"],"defaultEffort":"high"]]] as [String:Any] }
            else if path.hasSuffix("/sessions") { var first = Self.snapshot(); first.removeValue(forKey:"messages"); var second = first; second["id"] = "22222222-2222-4222-8222-222222222222"; second["name"] = "文件与产物管理"; var third = first; third["id"] = "33333333-3333-4333-8333-333333333333"; third["name"] = "会话与权限策略"; value = ["sessions":[first,second,third]] }
            else if path.hasSuffix("/workspace") || path.hasSuffix("/entries") { value = ["root":"/demo/AGY-Mac","path":"","entries":[["name":"Sources","path":"/demo/AGY-Mac/Sources","directory":true,"size":0,"modified":1793664000],["name":"Design","path":"/demo/AGY-Mac/Design","directory":true,"size":0,"modified":1793663000],["name":"README.md","path":"/demo/AGY-Mac/README.md","directory":false,"size":5280,"modified":1793662000],["name":"品牌图标.png","path":"/demo/AGY-Mac/品牌图标.png","directory":false,"size":Self.png.count,"modified":1793661000],["name":"实现方案.pdf","path":"/demo/AGY-Mac/实现方案.pdf","directory":false,"size":184320,"modified":1793660000]]] as [String:Any] }
            else if path.hasSuffix("/limits") { value = Self.quota }
            else if path.hasSuffix("/files") { respond(Self.png,mime:"image/png"); return }
            else { value = Self.snapshot() }
            respond(try JSONSerialization.data(withJSONObject:value),mime:"application/json")
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    private func respond(_ data: Data,mime: String) {
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime,"Content-Length":String(data.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static let quota: [String:Any] = ["fetchedAt":1793664000,"source":"离线界面示例","groups":[["name":"Gemini 系列模型","description":"该系列模型共享额度池","buckets":[["id":"five-hour","name":"5 小时额度","window":"5h","remaining_fraction":0.72,"reset_time":"2026-11-03T08:00:00Z"],["id":"weekly","name":"每周额度","window":"weekly","remaining_fraction":0.46,"reset_time":"2026-11-09T00:00:00Z"]]]]]
    static func snapshot() -> [String:Any] {
        let tools: [[String:Any]] = [
            ["id":"cmd-1","name":"run_command","state":"DONE","parameters":["CommandLine":"swift test --arch x86_64"],"output":"Test Suite 'All tests' passed.","isError":false],
            ["id":"read-1","name":"read_file","state":"DONE","parameters":["Path":"/demo/AGY-Mac/Sources/App.swift"],"output":"42 lines, 1280 bytes","isError":false],
            ["id":"edit-1","name":"edit_file","state":"DONE","parameters":["Path":"/demo/AGY-Mac/Sources/ChatView.swift","Target":"TextEditor(text:$store.text)","Replacement":"ComposerInputView(text:$store.text,\n    placeholder:\"描述任务…\",\n    isEditable:true)"],"output":"Edited file.","isError":false],
            ["id":"write-1","name":"write_file","state":"DONE","parameters":["Path":"/demo/AGY-Mac/Sources/ChangesBar.swift","Content":"import SwiftUI\nstruct ChangesBar: View {\n    var body: some View { Text(\"Changes\") }\n}"],"output":"Created file.","isError":false]
        ]
        let messages: [[String:Any]] = [
            ["id":"user-example","role":"user","text":"请查看项目结构，整理一个适合 Intel Mac 的原生客户端方案。","attachments":[],"tools":[],"steps":[]],
            ["id":"assistant-example","role":"assistant","text":"这是离线界面示例，用于检查真实原生窗口的排版。\n\n建议把客户端划分为三部分：\n\n**会话与工作区**：左侧切换项目和历史，右侧保留完整阅读空间。\n\n**文件与产物**：通过引用按钮选择文件或整个文件夹，下载集中放在消息底部。\n\n```swift\nstruct WorkspaceView: View {\n    var body: some View {\n        NavigationSplitView { Sidebar() } detail: { Chat() }\n    }\n}\n```\n\n模型、思考强度、审批策略分别设置，避免把不同选项混在一起。","attachments":[["id":"artifact-image","name":"品牌图标.png","mime":"image/png","size":png.count,"path":"/demo/AGY-Mac/品牌图标.png"],["id":"artifact-doc","name":"实现方案.md","mime":"text/markdown","size":2340,"path":"/demo/AGY-Mac/实现方案.md"]],"tools":tools,"steps":[["index":0,"text":"先阅读项目入口，再整理界面与工作流。","thinking":"保持平台原生习惯，让会话、文件与任务操作各自清晰。"]]]]
        let approvals: [[String:Any]] = approvalScene ? [["id":"44444444-4444-4444-8444-444444444444","sessionID":sessionID,"tool":"write_file","parameters":["path":"Sources/WorkspaceView.swift","reason":"调整会话布局"],"createdAt":1793664000,"expiresAt":1893664000]]:[]
        return ["id":sessionID,"name":"SwiftUI 客户端设计","cwd":"/demo/AGY-Mac","model":"gemini-medium","mode":"plan","modified":1793664000,"running":approvalScene,"conversationID":"","error":"","revision":approvalScene ? 2:1,"messages":messages,"baseModel":"gemini","effort":"medium","approvalMode":"review","approvals":approvals]
    }
}
#endif
