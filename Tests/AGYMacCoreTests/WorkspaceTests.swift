import XCTest
@testable import AGYMacCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MemoryStorage: StateStorage {
    var data: Data?, fail = false
    func load() throws -> AppState { try data.map { try JSONDecoder().decode(AppState.self,from:$0) } ?? AppState() }
    func save(_ state: AppState) throws { if fail { throw MacError.message("disk full") }; data = try JSONEncoder().encode(state) }
}
final class FixtureProtocol: URLProtocol {
    static var fixture: FixtureServer!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let value = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:value)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
final class FixtureServer {
    let id = "11111111-1111-4111-8111-111111111111"
    var profile = "one", loseResponse = false, messagePosts = 0
    var messageIDs: [String] = [], messages: [[String:Any]] = [], running = false
    private let lock = NSRecursiveLock()
    func snapshot() -> [String:Any] { ["id":id,"name":"历史对话","cwd":"/work","model":"gemini-medium","mode":"plan","modified":1,"running":running,"conversationID":"","error":"","revision":messages.count,"messages":messages,"baseModel":"gemini","effort":"medium","approvalMode":"review","approvals":[]] }
    func respond(_ request: URLRequest) throws -> Any {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/status") { return ["name":"Fixture","version":1,"roots":["/work"],"defaultModel":"gemini-medium","accountProfile":profile,"capabilities":["separateEffort":true,"nativeApprovals":true,"fileBrowser":true,"directoryMentions":true]] as [String:Any] }
        if path.hasSuffix("/models") { return ["models":[["id":"gemini-medium","name":"Gemini"]],"families":[["id":"gemini","name":"Gemini","variants":[["id":"gemini-medium","effort":"medium"],["id":"gemini-high","effort":"high"]],"efforts":["medium","high"],"defaultEffort":"medium"]]] as [String:Any] }
        if path.hasSuffix("/sessions") { if request.httpMethod == "POST" { return snapshot() }; return ["sessions":[snapshot()]] }
        if path.hasSuffix("/workspace") { return ["root":"/work","path":"","entries":[]] as [String:Any] }
        if path.hasSuffix("/stop") { running = false; return snapshot() }
        if path.hasSuffix("/messages") {
            messagePosts += 1
            // FoundationNetworking may represent POST data as a body stream.
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var result = Data(); var buffer = [UInt8](repeating:0,count:4096); while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; result.append(contentsOf:buffer.prefix(n)) }; bytes = result }
            let body = try JSONSerialization.jsonObject(with:bytes ?? Data()) as! [String:Any]
            let rid = body["requestID"] as! String; messageIDs.append(rid)
            if !messages.contains(where:{$0["id"] as? String == rid}) { messages.append(["id":rid,"role":"user","text":body["text"] as? String ?? "","attachments":[],"tools":[],"steps":[]]) }
            if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        }
        return snapshot()
    }
}
final class WorkspaceTests: XCTestCase {
    @MainActor private func workspace(_ fixture: FixtureServer, _ storage: MemoryStorage) throws -> Workspace {
        FixtureProtocol.fixture = fixture
        return try Workspace(storage:storage,watchEnabled:false,factory:{ credentials,_ in let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]; return GatewayClient(credentials:credentials,configuration:config) })
    }
    @MainActor func testLostResponseReconcilesAfterRestartWithoutResend() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(), credentials = try Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))
        let first = try workspace(fixture,storage); try await first.connect(credentials); try first.updateDraft("不要重复发送"); fixture.loseResponse = true
        do { try await first.send(); XCTFail("expected lost response") } catch {}
        XCTAssertNotNil(first.pending); XCTAssertEqual(fixture.messagePosts,1)
        let second = try workspace(fixture,storage); try await second.connect(credentials)
        XCTAssertNil(second.pending); XCTAssertEqual(fixture.messagePosts,1); XCTAssertEqual(second.draft.text,"")
        try second.disconnect(); try first.disconnect()
    }
    @MainActor func testPersistenceFailureStopsMessageAndRetainsDraft() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(); let engine = try workspace(fixture,storage)
        try await engine.connect(Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))); try engine.updateDraft("保留我")
        storage.fail = true; do { try await engine.send(); XCTFail("expected disk failure") } catch {}
        XCTAssertEqual(fixture.messagePosts,0); XCTAssertEqual(engine.draft.text,"保留我")
        storage.fail = false; try engine.disconnect()
    }
    @MainActor func testDefaultsAndFoldersStayScopedToAccount() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(); let engine = try workspace(fixture,storage)
        let credentials = try Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))
        try await engine.connect(credentials)
        var settings = engine.settings; settings.approvalMode = "turbo"; settings.effort = "high"; try await engine.configure(settings)
        try engine.addReference(FileReference(path:"/work/src",label:"src/",directory:true))
        try await engine.select(fixture.id); XCTAssertEqual(engine.settings.approvalMode,"review")
        try engine.newConversation(); XCTAssertEqual(engine.settings.approvalMode,"turbo"); XCTAssertTrue(engine.draft.references.first?.directory == true)
        fixture.profile = "two"; try await engine.connect(credentials); XCTAssertEqual(engine.settings.approvalMode,"review"); XCTAssertTrue(engine.draft.references.isEmpty)
        fixture.profile = "one"; try await engine.connect(credentials); XCTAssertEqual(engine.settings.effort,"high"); XCTAssertEqual(engine.draft.references.first?.path,"/work/src"); try engine.disconnect()
    }
    @MainActor func testQueuePersistsWithoutPostingAndImmediateSteeringStopsFirst() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(); let engine = try workspace(fixture,storage)
        try await engine.connect(Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))); fixture.running = true; try await engine.select(fixture.id)
        try engine.updateDraft("下一步改界面"); try await engine.enqueue()
        XCTAssertEqual(engine.queue.count,1); XCTAssertEqual(fixture.messagePosts,0); XCTAssertEqual(engine.draft.text,"")
        let queuedID = engine.queue[0].id; XCTAssertEqual(try storage.load().profiles[engine.scope]?.queues[fixture.id]?.first?.id,queuedID)
        try engine.removeQueued(queuedID,edit:true); XCTAssertEqual(engine.draft.text,"下一步改界面")
        try await engine.steer(); XCTAssertFalse(fixture.running); XCTAssertEqual(fixture.messagePosts,1); XCTAssertNil(engine.pending); try engine.disconnect()
    }
    @MainActor func testExplicitRetryKeepsOriginalRequestID() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(); let engine = try workspace(fixture,storage)
        try await engine.connect(Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))); try engine.updateDraft("same id"); fixture.loseResponse = true
        do { try await engine.send() } catch {}
        let original = engine.pending!.requestID; try await engine.submitPending()
        XCTAssertEqual(fixture.messageIDs,[original,original]); XCTAssertEqual(fixture.messages.count,1); XCTAssertNil(engine.pending); try engine.disconnect()
    }
    @MainActor func testAccountChangeNeverPostsToNewAccount() async throws {
        let fixture = FixtureServer(), storage = MemoryStorage(); let engine = try workspace(fixture,storage)
        try await engine.connect(Credentials(address:"https://fixture.test",token:String(repeating:"k",count:48))); try engine.updateDraft("old account only")
        fixture.profile = "two"; do { try await engine.send(); XCTFail("expected account mismatch") } catch {}
        XCTAssertEqual(fixture.messagePosts,0); XCTAssertFalse(engine.connected)
    }
}
