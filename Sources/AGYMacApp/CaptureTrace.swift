#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Combine

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
    private var store: MacStore?
    private var window: NSWindow?
    private var settings: NSWindow?
    private var appearanceObserver: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        CaptureTrace.mark("application.didFinishLaunching")
        let store = MacStore(); self.store = store
        let controller = NSHostingController(rootView:RootView().environmentObject(store))
        let window = NSWindow(contentViewController:controller)
        window.title = "AGY · Mac"; window.styleMask = [.titled,.closable,.miniaturizable,.resizable]
        window.isOpaque = true; window.backgroundColor = .windowBackgroundColor; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = false; window.toolbarStyle = .unifiedCompact
        window.setContentSize(NSSize(width:1220,height:820)); window.minSize = NSSize(width:800,height:600)
        window.isReleasedWhenClosed = false; self.window = window
        appearanceObserver = store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateAppearance() } }
        updateAppearance()
        installMenu(); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        CaptureTrace.mark("application.windowCreated id=\(window.windowNumber)")
        Task { await store.restore(); if store.captureEnabled { await UICapture.run(store) } else if HybridVerification.enabled { await HybridVerification.run(store) } }
    }
    private func updateAppearance() {
        guard let store else { return }
        let appearance: NSAppearance? = store.colorScheme == .dark ? NSAppearance(named:.darkAqua):store.colorScheme == .light ? NSAppearance(named:.aqua):nil
        window?.appearance = appearance; settings?.appearance = appearance
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store?.hybridWorker.stop(); store?.localBuild.stop() }
    private func installMenu() {
        let main = NSMenu(), app = NSMenu(), file = NSMenu(), navigation = NSMenu(), windows = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)
        app.addItem(item("关于 AGY · Mac",#selector(about),"")); app.addItem(.separator())
        app.addItem(item("设置…",#selector(openSettings),",")); app.addItem(.separator())
        app.addItem(NSMenuItem(title:"退出 AGY · Mac",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let fileItem = NSMenuItem(title:"文件",action:nil,keyEquivalent:""); fileItem.submenu = file; main.addItem(fileItem)
        file.addItem(item("新建对话",#selector(newConversation),"n")); file.addItem(item("文件与产物",#selector(showFiles),"2"))
        let navigationItem = NSMenuItem(title:"AGY",action:nil,keyEquivalent:""); navigationItem.submenu = navigation; main.addItem(navigationItem)
        navigation.addItem(item("模型与任务配置…",#selector(taskOptions),"k")); navigation.addItem(item("刷新会话",#selector(refresh),"r")); navigation.addItem(item("停止本机构建",#selector(stopBuild),"."))
        let windowItem = NSMenuItem(title:"窗口",action:nil,keyEquivalent:""); windowItem.submenu = windows; main.addItem(windowItem)
        windows.addItem(NSMenuItem(title:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")); NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
    private func item(_ title: String,_ action: Selector,_ key: String) -> NSMenuItem { let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.target = self; return item }
    @objc private func newConversation() { guard let store,store.connected else { return }; store.run { try await store.newConversation() } }
    @objc private func showFiles() { if store?.connected == true { store?.page = .files } }
    @objc private func taskOptions() { if store?.connected == true { store?.showTaskOptions = true } }
    @objc private func refresh() { guard let store,store.connected else { return }; store.run { try await store.reload() } }
    @objc private func stopBuild() { store?.hybridWorker.stop(); store?.localBuild.stop() }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func openSettings() {
        guard let store else { return }
        if let settings { settings.makeKeyAndOrderFront(nil); return }
        let controller = NSHostingController(rootView:PreferencesView().environmentObject(store).frame(width:680,height:720).preferredColorScheme(store.colorScheme))
        let win = NSWindow(contentViewController:controller); win.title = "AGY · Mac 设置"; win.styleMask = [.titled,.closable]; win.isReleasedWhenClosed = false
        settings = win; updateAppearance(); win.center(); win.makeKeyAndOrderFront(nil)
    }
}
#endif
