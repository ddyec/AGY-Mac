#if os(macOS)
import SwiftUI
import AppKit
import AGYMacCore

@MainActor enum UICapture {
    private static var started = false
    static func run(_ store: MacStore) async {
        guard !started else { return }; started = true; CaptureTrace.mark("capture.begin")
        let args = ProcessInfo.processInfo.arguments
        let index = args.firstIndex(of:"--output")
        let path = index.flatMap { $0 + 1 < args.count ? args[$0+1]:nil } ?? FileManager.default.temporaryDirectory.appendingPathComponent("AGY-Mac-Captures").path
        let folder = URL(fileURLWithPath:path,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
            try await Task.sleep(nanoseconds:800_000_000)
            guard let window = NSApp.windows.first(where:{$0.isVisible && $0.canBecomeMain}) else { throw MacError.message("没有可截图的原生窗口。") }
            CaptureTrace.mark("capture.window=\(window.windowNumber)")
            window.setContentSize(NSSize(width:1220,height:820)); window.center(); window.makeKeyAndOrderFront(nil)
            var captured: [[String:Any]] = []
            func capture(_ name: String) async throws {
                try await Task.sleep(nanoseconds:900_000_000)
                CaptureTrace.mark("capture.start "+name)
                let target = name.hasPrefix("model-dialog") ? (window.attachedSheet ?? window):window
                let image = folder.appendingPathComponent(name+".png")
                let command = Process(); command.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture"); command.arguments = ["-x","-o","-l",String(target.windowNumber),image.path]
                command.standardError = FileHandle.standardError
                let result: Int32 = try await withCheckedThrowingContinuation { continuation in
                    command.terminationHandler = { process in continuation.resume(returning:process.terminationStatus) }
                    do { try command.run() } catch { continuation.resume(throwing:error) }
                }
                let fullWindow = result == 0 && FileManager.default.fileExists(atPath:image.path)
                CaptureTrace.mark("capture.screencapture "+name+" status=\(command.terminationStatus)")
                guard fullWindow else { throw MacError.message("系统窗口截图失败，请查看 stage.log 与 capture.log。") }
                guard let view = target.contentView else { throw MacError.message("窗口内容不存在。") }
                captured.append(["name":name,"fullNativeWindow":fullWindow,"windowID":window.windowNumber,"width":Int(view.bounds.width),"height":Int(view.bounds.height),"theme":store.captureTheme ?? "system"])
                print("Captured \(name); native window=\(fullWindow)")
            }
            for theme in ["light","dark"] { store.captureTheme = theme; window.appearance = NSAppearance(named:theme == "light" ? .aqua:.darkAqua); try await capture("login-"+theme) }
            let connection = try Credentials(address:"https://preview.invalid",token:String(repeating:"p",count:48)); try await store.engine.connect(connection)
            store.limits = try JSONDecoder().decode(LimitReply.self,from:JSONSerialization.data(withJSONObject:VisualFixture.quota))
            for theme in ["light","dark"] {
                store.captureTheme = theme; window.appearance = NSAppearance(named:theme == "light" ? .aqua:.darkAqua)
                try store.engine.preferences(theme:theme)
                try store.engine.newConversation(); store.page = .chat; try await capture("workspace-"+theme)
                try await store.engine.select(VisualFixture.sessionID); try await capture("conversation-"+theme)
                store.showTaskOptions = true; try await capture("model-dialog-"+theme); store.showTaskOptions = false
                try await Task.sleep(nanoseconds:400_000_000)
                store.page = .files; try await capture("files-"+theme)
                store.localBuild.folder = "/Users/demo/Projects/AGY-Mac"; store.localBuild.command = "swift build -c release --arch x86_64"; store.page = .builds; try await capture("build-"+theme)
                store.page = .settings; try await capture("settings-"+theme)
                store.page = .skills; try await capture("skills-"+theme)
            }
            store.page = .chat; window.setContentSize(NSSize(width:900,height:660)); try await capture("conversation-compact-dark")
            window.setContentSize(NSSize(width:1220,height:820)); VisualFixture.approvalScene = true; try await store.engine.select(VisualFixture.sessionID)
            try store.engine.updateDraft("任务完成后，请继续检查文件引用。"); try await store.engine.enqueue(); store.text = "请优先调整输入区的间距。"; try await capture("approval-and-queue-dark")
            let report: [String:Any] = ["nativeAppLaunched":true,"architecture":"x86_64","os":ProcessInfo.processInfo.operatingSystemVersionString,"fixture":"offline; no keychain or external network","captures":captured,"visualReviewCompleted":false]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("capture-manifest.json"))
            try Data("success\n".utf8).write(to:folder.appendingPathComponent("capture.complete"))
            NSApp.terminate(nil)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to:folder.appendingPathComponent("capture-error.txt")); fputs("UI capture failed: \(error.localizedDescription)\n",stderr); exit(1)
        }
    }
}
#endif
