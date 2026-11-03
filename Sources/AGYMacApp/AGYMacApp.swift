#if os(macOS)
import SwiftUI
import AppKit
import AGYMacCore
#if !arch(x86_64)
#error("AGY-Mac is an Intel x86_64 app. Build with --arch x86_64.")
#endif
@main @MainActor struct AGYMacApp: App {
    @StateObject private var store = MacStore()
    var body: some Scene {
        WindowGroup("AGY · Mac") { RootView().environmentObject(store).frame(minWidth: 780, minHeight: 560).task { await store.restore(); if store.captureEnabled { await UICapture.run(store) } }.preferredColorScheme(store.colorScheme) }
            .defaultSize(width: 1220, height: 820)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(replacing: .newItem) { Button("新建对话") { store.run { try await store.newConversation() } }.keyboardShortcut("n").disabled(!store.connected) }
                CommandMenu("AGY") {
                    Button("停止本机构建") { store.localBuild.stop() }.keyboardShortcut(".").disabled(!store.localBuild.running)
                    Button("模型与任务配置…") { store.showTaskOptions = true }.keyboardShortcut("k").disabled(!store.connected)
                    Button("文件与产物") { store.page = .files }.keyboardShortcut("2").disabled(!store.connected)
                    Button("刷新会话") { store.run { try await store.reload() } }.keyboardShortcut("r", modifiers: [.command,.shift]).disabled(!store.connected)
                }
            }
        Settings { PreferencesView().environmentObject(store).frame(width: 640, height: 650).preferredColorScheme(store.colorScheme) }
    }
}
#else
import Foundation
@main struct UnsupportedHost { static func main() { print("AGY-Mac GUI requires Intel macOS 13 or later. Core tests can run on Linux.") } }
#endif
