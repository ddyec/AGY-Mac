#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import Darwin
import AGYMacCore

@MainActor final class LocalBuild: ObservableObject {
    @Published var folder = ""
    @Published var command = ""
    @Published var log = ""
    @Published var running = false
    @Published private(set) var exitCode: Int32?
    var outputLogURL: URL? { logURL }
    private var process: Process?, logURL: URL?, poll: Task<Void,Never>?
    private var offset: UInt64 = 0
    func reset() { guard !running else { return }; folder = ""; command = ""; log = ""; logURL = nil; offset = 0 }
    func start() throws {
        guard !running else { throw MacError.message("已有本机构建在运行。") }
        let cwd = URL(fileURLWithPath:folder,isDirectory:true)
        guard !command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, (try? cwd.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true else { throw MacError.message("请选择本机项目目录并填写构建命令。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AGY-Mac-Build-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = directory.appendingPathComponent("build.log"), header = "Intel Mac · \(folder)\n$ \(command)\n"
        try Data(header.utf8).write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let writer = try FileHandle(forWritingTo:file); try writer.seekToEnd()
        let child = Process(); child.executableURL = URL(fileURLWithPath:"/usr/bin/arch"); child.arguments = ["-x86_64","/bin/zsh","-lc",command]; child.currentDirectoryURL = cwd; child.standardOutput = writer; child.standardError = writer
        log = ""; offset = 0; logURL = file; running = true; exitCode = nil; process = child
        child.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                guard let self else { return }; self.poll?.cancel(); self.readLog()
                let status = "\n退出码：\(child.terminationStatus)\n"; self.log += status
                if let handle = try? FileHandle(forWritingTo:file) { defer { try? handle.close() }; do { try handle.seekToEnd(); try handle.write(contentsOf:Data(status.utf8)) } catch {} }
                self.exitCode = child.terminationStatus; self.running = false; self.process = nil
            }
        }
        do { try child.run(); try writer.close() }
        catch { try? writer.close(); running = false; process = nil; throw error }
        poll = Task { [weak self] in while !Task.isCancelled { guard let self else { return }; self.readLog(); try? await Task.sleep(nanoseconds:200_000_000) } }
    }
    private func readLog() {
        guard let url = logURL, log.utf8.count < 2 * 1024 * 1024, let reader = try? FileHandle(forReadingFrom:url) else { return }
        defer { try? reader.close() }
        do { try reader.seek(toOffset:offset); if let bytes = try reader.read(upToCount:256*1024), !bytes.isEmpty { offset += UInt64(bytes.count); log += String(decoding:bytes,as:UTF8.self) } } catch {}
    }
    func stop() {
        guard let process, process.isRunning else { return }
        let descendants = childProcesses(process.processIdentifier,depth:0)
        for child in descendants.reversed() { if child > 1 { _ = Darwin.kill(child,SIGTERM) } }
        process.terminate()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:3_000_000_000)
            guard let self, self.process === process, process.isRunning else { return }
            for child in self.childProcesses(process.processIdentifier,depth:0).reversed() { if child > 1 { _ = Darwin.kill(child,SIGKILL) } }
            _ = Darwin.kill(process.processIdentifier,SIGKILL)
        }
    }
    private func childProcesses(_ pid: Int32, depth: Int) -> [Int32] {
        guard depth < 16 else { return [] }
        let reader = Process(), output = Pipe(); reader.executableURL = URL(fileURLWithPath:"/usr/bin/pgrep"); reader.arguments = ["-P",String(pid)]; reader.standardOutput = output; reader.standardError = FileHandle.nullDevice
        do { try reader.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); reader.waitUntilExit(); let children = String(decoding:data,as:UTF8.self).split(whereSeparator:\.isNewline).compactMap { Int32($0) }.prefix(128); return children.flatMap { [$0] + childProcesses($0,depth:depth+1) } } catch { return [] }
    }
    func uploadLog(_ store: MacStore) async throws { guard let logURL, !running else { throw MacError.message("构建结束后可回传日志。") }; try await store.engine.upload(logURL,reference:false) }
    func synchronize(_ store: MacStore) async throws {
        let temporary = try await store.engine.download(store.engine.settings.workspace,snapshot:true); defer { try? FileManager.default.removeItem(at:temporary) }
        let base = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AGY-Mac/Workspaces/" + UUID().uuidString,isDirectory:true)
        let bytes = try Data(contentsOf:temporary)
        try await Task.detached { try SnapshotArchive.extract(bytes,to:base) }.value
        folder = base.path; log = "项目已同步到新的本机副本，没有覆盖原有目录。"
    }
}
#endif
