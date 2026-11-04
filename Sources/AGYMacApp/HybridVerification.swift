#if os(macOS)
import Foundation
import AppKit
import AGYMacCore

/// Explicit CI-only mode: no credentials, real network, or model calls.
enum HybridVerification {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--verify-hybrid") }
    private static let lock = NSLock()
    private static var claimed = false
    private static var completed: [String:Any]?
    static let jobID = "55555555-5555-4555-8555-555555555555"
    static var result: [String:Any]? { lock.lock(); defer { lock.unlock() }; return completed }
    static func trace(_ text: String) {
        guard enabled, let index = ProcessInfo.processInfo.arguments.firstIndex(of:"--output") else { return }
        let file = URL(fileURLWithPath:ProcessInfo.processInfo.arguments[index+1]).appendingPathComponent("hybrid-stages.log")
        let data = Data((Date().description+" "+text+"\n").utf8)
        if let h = try? FileHandle(forWritingTo:file) { defer { try? h.close() }; try? h.seekToEnd(); try? h.write(contentsOf:data) } else { try? data.write(to:file) }
    }
    static func response(_ request: URLRequest) throws -> (Data,String)? {
        guard enabled else { return nil }
        let path = request.url!.path
        trace((request.httpMethod ?? "GET")+" "+path)
        var value: [String:Any]
        if path.hasSuffix("/device") { value = ["accountProfile":"offline-preview"] }
        else if path.hasSuffix("/poll") {
            lock.lock(); let first = !claimed; claimed = true; lock.unlock()
            value = ["accountProfile":"offline-preview","job": first ? ["id":jobID,"sessionID":VisualFixture.sessionID,"command":"printf 'HYBRID_NATIVE_OK\\n'; /usr/bin/uname -m > output.txt","subdirectory":".","artifacts":["output.txt"],"deadline":Date().timeIntervalSince1970+60]:NSNull(),"lease":"offline-test-lease"]
        } else if path.hasSuffix("/snapshot") {
            return (Data(base64Encoded:"UEsDBBQAAAAIAC5PZF2kBxD5KAAAACYAAAAJAAAAUkVBRE1FLm1k86hMKspMUUgqzcxJUchLLMksS1VIrUhNLi3JzM9TSMusKCktSuUCAFBLAQIUAxQAAAAIAC5PZF2kBxD5KAAAACYAAAAJAAAAAAAAAAAAAACAAQAAAABSRUFETUUubWRQSwUGAAAAAAEAAQA3AAAATwAAAAAA")!,"application/zip")
        } else if path.hasSuffix("/attachments") {
            let name = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "name"})?.value ?? "output"
            value = ["id":UUID().uuidString.lowercased(),"name":name,"mime":"text/plain","size":1,"path":"/demo/AGY-Mac/"+name]
        } else if path.contains("/builds/") {
            if let data = bodyData(request), let body = try JSONSerialization.jsonObject(with:data) as? [String:Any], body["complete"] as? Bool == true {
                lock.lock(); completed = body["result"] as? [String:Any]; lock.unlock(); trace("result received")
            }
            value = ["accountProfile":"offline-preview","active":true]
        } else { return nil }
        return (try JSONSerialization.data(withJSONObject:value),"application/json")
    }
    private static func bodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable { let n = stream.read(&bytes,maxLength:bytes.count); if n <= 0 { break }; data.append(contentsOf:bytes.prefix(n)) }
        return data
    }
    @MainActor static func run(_ store: MacStore) async {
        let args = ProcessInfo.processInfo.arguments
        let index = args.firstIndex(of:"--output")!
        let folder = URL(fileURLWithPath:args[index+1],isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try await store.engine.connect(Credentials(address:"https://preview.invalid",token:String(repeating:"p",count:48)))
            try await store.engine.select(VisualFixture.sessionID)
            try await store.hybridWorker.prepare(VisualFixture.sessionID,store:store)
            let deadline = Date().addingTimeInterval(60)
            while result == nil && Date() < deadline { try await Task.sleep(nanoseconds:200_000_000) }
            trace("final result: "+String(describing:result))
            guard let result, result["exitCode"] as? Int == 0, (result["log"] as? String)?.contains("HYBRID_NATIVE_OK") == true, (result["attachments"] as? [String])?.count == 2 else { throw MacError.message("Native worker did not return successful command, log and artifact: \(store.hybridWorker.status)") }
            let output = URL(fileURLWithPath:store.localBuild.folder).appendingPathComponent("output.txt")
            guard try String(contentsOf:output).trimmingCharacters(in:.whitespacesAndNewlines) == "x86_64" else { throw MacError.message("Worker did not execute on Intel Mac") }
            store.hybridWorker.stop()
            try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("hybrid-verification.json"))
            try Data("native dispatch, snapshot extraction, Intel process execution, log and artifact upload, result return: success\n".utf8).write(to:folder.appendingPathComponent("hybrid.complete"))
            NSApp.terminate(nil)
        } catch { try? Data(error.localizedDescription.utf8).write(to:folder.appendingPathComponent("hybrid-error.txt")); exit(1) }
    }
}
#endif
