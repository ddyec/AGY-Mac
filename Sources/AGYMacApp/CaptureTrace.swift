#if os(macOS)
import Foundation
import AppKit

@MainActor enum CaptureTrace {
    static func mark(_ text: String) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--capture-ui"), let i = args.firstIndex(of:"--output"), i+1 < args.count else { return }
        let folder = URL(fileURLWithPath:args[i+1],isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file = folder.appendingPathComponent("stage.log"), bytes = Data((Date().description+" "+text+"\n").utf8)
        if let handle = try? FileHandle(forWritingTo:file) { defer { try? handle.close() }; try? handle.seekToEnd(); try? handle.write(contentsOf:bytes) } else { try? bytes.write(to:file) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureTrace.mark("application.didFinishLaunching windows=\(NSApp.windows.count)")
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
    }
}
#endif
