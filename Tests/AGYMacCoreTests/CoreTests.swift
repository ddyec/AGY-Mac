import XCTest
@testable import AGYMacCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CoreTests: XCTestCase {
    let key = String(repeating:"k",count:48)
    func testHTTPSOriginAndCredentials() throws {
        for address in ["http://gateway.test","https://user:pass@gateway.test","https://gateway.test/path","https://gateway.test/?token=x","https://gateway.test/#x"] { XCTAssertThrowsError(try Credentials(address:address,token:key)) }
        XCTAssertThrowsError(try Credentials(address:"https://gateway.test",token:key+"\n"))
        XCTAssertEqual(try Credentials(address:"https://gateway.test/",token:key).origin,"https://gateway.test")
    }
    func testRequestNeverPutsTokenIntoURL() throws {
        let client = GatewayClient(credentials:try Credentials(address:"https://gateway.test",token:key))
        let request = try client.request("workspace",query:["path":"中文 空格/#file.md"])
        XCTAssertEqual(request.url?.host,"gateway.test"); XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer " + key)
        XCTAssertFalse(request.url!.absoluteString.contains(key)); XCTAssertEqual(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,"中文 空格/#file.md")
        XCTAssertThrowsError(try client.request("https://other.test")); XCTAssertThrowsError(try client.request("../files"))
    }
    func testRedirectAnd502AreErrors() throws {
        let client = GatewayClient(credentials:try Credentials(address:"https://gateway.test",token:key))
        for code in [302,401,502] { XCTAssertThrowsError(try client.validate(HTTPURLResponse(url:URL(string:"https://gateway.test")!,statusCode:code,httpVersion:nil,headerFields:nil)!)) }
    }
    func testReferencesPreserveWholeFoldersAndUnicode() {
        XCTAssertEqual(FileRules.label(scope:"workspace",folder:"项目",name:"src",directory:true),"项目/src/")
        XCTAssertEqual(FileRules.label(scope:"uploads",folder:"",name:"图片.png",directory:false),"上传/图片.png")
        XCTAssertFalse(FileRules.within("/work/../etc",root:"/work")); XCTAssertFalse(FileRules.within("/work-other",root:"/work")); XCTAssertTrue(FileRules.within("/work/folder",root:"/"))
        XCTAssertEqual(FileRules.safeName("../../中文 合同.pdf"),"中文 合同.pdf")
    }
    func testModelAndEffortAreIndependentAndTurboNeverInheritedByDefault() throws {
        let families = try JSONDecoder().decode([ModelFamily].self,from:Data(#"[{"id":"gemini","name":"Gemini","variants":[{"id":"gemini-medium","effort":"medium"},{"id":"gemini-high","effort":"high"}],"efforts":["medium","high"],"defaultEffort":"medium"}]"#.utf8))
        var value = TaskSettings(); try value.validate(families,roots:["/work"],defaultModel:"gemini-medium")
        XCTAssertEqual(value.model,"gemini"); XCTAssertEqual(value.effort,"medium"); XCTAssertEqual(value.approvalMode,"review"); XCTAssertEqual(value.workspace,"/work")
        value.effort = "high"; try value.validate(families,roots:["/work"],defaultModel:"gemini-medium"); XCTAssertEqual(value.effort,"high")
    }
    func testSSEFramingDoesNotDropBlankLinesOrUnicode() throws {
        var frame = SSEFramer(); var result: [String] = []
        for byte in Data("\u{FEFF}: ping\r\ndata: 中文\r\ndata: second\r\n\r\ndata: incomplete".utf8) { if let text = try frame.consume(byte) { result.append(text) } }
        XCTAssertEqual(result,["中文\nsecond"])
    }
    func testPendingIDAndExactReferencesSurviveRoundtrip() throws {
        var draft = Draft(); draft.text = "查看此目录"; draft.references = [FileReference(path:"/work/中文 文件夹",label:"中文 文件夹/",directory:true)]
        let pending = PendingSend(sessionID:"11111111-1111-4111-8111-111111111111",draft:draft)
        let restored = try JSONDecoder().decode(PendingSend.self,from:JSONEncoder().encode(pending))
        XCTAssertEqual(restored.requestID,pending.requestID); XCTAssertEqual(restored.references.count,1); XCTAssertTrue(restored.references[0].directory); XCTAssertEqual(restored.body["references"].array,[.string("/work/中文 文件夹")])
    }
    func testEncryptedStorageFailurePreservesPreviousFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("state.bin")
        let crypt: (Data) -> Data = { Data($0.map { $0 ^ 0xA5 }) }
        let storage = AtomicStateStorage(url:file,seal:crypt,open:crypt)
        var state = AppState(); var profile = ProfileState(); profile.settings.model = "secret-model"; state.profiles["server#one"] = profile; try storage.save(state)
        let data = try Data(contentsOf:file); XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("secret-model"))
        XCTAssertEqual(try storage.load().profiles["server#one"]?.settings.model,"secret-model")
        let failing = AtomicStateStorage(url:file,seal:{_ in throw MacError.message("disk")},open:crypt)
        XCTAssertThrowsError(try failing.save(AppState())); XCTAssertEqual(try Data(contentsOf:file),data)
    }
    func testRemoteArtifactsNeverUseUnrelatedHostOrLocalFileRead() throws {
        let origin = URL(string:"https://gateway.test")!
        XCTAssertNil(RemoteLinks.path("https://other.test/api/files/download?path=/etc/passwd",origin:origin,cwd:"/work"))
        XCTAssertNil(RemoteLinks.path("file://other.test/etc/passwd",origin:origin,cwd:"/work"))
        XCTAssertNil(RemoteLinks.path("../secret.txt",origin:origin,cwd:"/work"))
        XCTAssertEqual(RemoteLinks.path("sandbox:/work/产物.pdf",origin:origin,cwd:"/work"),"/work/产物.pdf")
        XCTAssertEqual(RemoteLinks.path("https://gateway.test/api/files/download?path=%2Fwork%2Fa.txt",origin:origin,cwd:"/work"),"/work/a.txt")
    }
    func testNetworkSettingsRejectInvalidResolversAndProxySecrets() throws {
        var value = NetworkSettings(); value.encryptedDNS = true; value.customDNS = "http://dns.test/query"; XCTAssertThrowsError(try value.validate())
        value.customDNS = "https://dns.test/dns-query"; value.proxy = "http://user:pass@proxy.test:8080"; XCTAssertThrowsError(try value.validate())
        value.proxy = "socks5://127.0.0.1:7891"; XCTAssertNoThrow(try value.validate())
        value.proxy = "http://proxy.test:8080/path"; XCTAssertThrowsError(try value.validate())
    }
    func testSnapshotRejectsTraversalSymlinksAndMacCaseCollisions() throws {
        XCTAssertNoThrow(try SnapshotArchive.validate(zip([("src/中文.txt",0x8000), ("README.md",0x8000)])))
        for entries in [[("../escape",0x8000)],[("/absolute",0x8000)],[("link",0xA000)],[("A.txt",0x8000),("a.txt",0x8000)],[("é.txt",0x8000),("e\u{301}.txt",0x8000)],[("a",0x8000),("a/file",0x8000)]] { XCTAssertThrowsError(try SnapshotArchive.validate(zip(entries))) }
        var data = zip([("good",0x8000)]); data[30] = 0x2F; XCTAssertThrowsError(try SnapshotArchive.validate(data))
    }
    func testSnapshotExtractPreservesCompressedUnicodeAndBinaryAndNeverOverwrites() throws {
        let zip = Data(base64Encoded:"UEsDBBQAAAgIAHUEY13vifCEDwAAAA0AAAAOAAAAc3JjL+S4reaWhy50eHR7smPts2ntDEmZeYlFlQBQSwMEFAAAAAgAdQRjXR22fUYGAAAABAAAAAkAAABpbWFnZS5iaW5j+M9YDwBQSwECFAMUAAAICAB1BGNd74nwhA8AAAANAAAADgAAAAAAAAAAAAAAgAEAAAAAc3JjL+S4reaWhy50eHRQSwECFAMUAAAACAB1BGNdHbZ9RgYAAAAEAAAACQAAAAAAAAAAAAAAgAE7AAAAaW1hZ2UuYmluUEsFBgAAAAACAAIAcwAAAGgAAAAAAA==")!
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:target) }
        try SnapshotArchive.extract(zip,to:target)
        XCTAssertEqual(try String(contentsOf:target.appendingPathComponent("src/中文.txt"),encoding:.utf8),"中文\0binary")
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("image.bin")),Data([0,255,1,127]))
        XCTAssertThrowsError(try SnapshotArchive.extract(zip,to:target))
    }
    func testProcessSummaryAndCodexFileChangesCalculation() throws {
        let tools: [ToolCall] = [
            ToolCall(id:"1",name:"run_command",state:"DONE",parameters:.object(["CommandLine":.string("uname -a")]),output:"Darwin",isError:false),
            ToolCall(id:"2",name:"read_file",state:"DONE",parameters:.object(["Path":.string("/work/Sources/A.swift")]),output:"10 lines, 200 bytes",isError:false),
            ToolCall(id:"3",name:"edit_file",state:"DONE",parameters:.object(["Path":.string("/work/Sources/A.swift"),"Target":.string("let a = 1\nlet b = 2"),"Replacement":.string("let a = 1\nlet b = 20\nlet c = 30")]),output:"",isError:false),
            ToolCall(id:"4",name:"write_file",state:"DONE",parameters:.object(["Path":.string("/work/Sources/B.swift"),"Content":.string("import Foundation\nstruct B {}\n")]),output:"",isError:false)
        ]
        let msg = ChatMessage(id:"m1",role:"assistant",text:"已完成修改。",attachments:nil,tools:tools,steps:[ResponseStep(index:0,text:"先检查代码",thinking:"分析结构")])
        let process = RemoteLinks.processSummary(for:msg,cwd:"/work")
        XCTAssertEqual(process.commandCount,1)
        XCTAssertEqual(process.writtenFileCount,2)
        XCTAssertEqual(process.readFileCount,1)
        XCTAssertEqual(process.headerTitle,"思考摘要 · 运行了 1 次指令 · 写入了 2 个文件 · 读取了 1 个文件")

        let changes = RemoteLinks.sessionChanges([msg],cwd:"/work")
        XCTAssertEqual(changes.totalCount,2)
        XCTAssertEqual(changes.completedCount,2)
        XCTAssertEqual(changes.statusText,"2 / 2 个文件已修改")
        XCTAssertEqual(changes.totalAdded,5)
        XCTAssertEqual(changes.totalRemoved,1)
    }
    private func zip(_ files: [(String,Int)]) -> Data {
        func n(_ value: Int,_ size: Int) -> Data { Data((0..<size).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
        func append(_ fields: [(Int,Int)], to data: inout Data) { for field in fields { data.append(n(field.0,field.1)) } }
        var data = Data(), central = Data()
        for (name,mode) in files {
            let filename = Data(name.utf8), offset = data.count
            append([(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,4),(0,4),(0,4),(0,4),(filename.count,2),(0,2)],to:&data); data.append(filename)
            append([(0x02014b50,4),(0x0314,2),(20,2),(0x800,2),(0,2),(0,4),(0,4),(0,4),(0,4),(filename.count,2),(0,2),(0,2),(0,2),(0,2),(mode << 16,4),(offset,4)],to:&central); central.append(filename)
        }
        let start = data.count; data.append(central)
        append([(0x06054b50,4),(0,2),(0,2),(files.count,2),(files.count,2),(central.count,4),(start,4),(0,2)],to:&data); return data
    }
}
