#if os(macOS)
import AppKit
import SwiftUI
#if !arch(x86_64)
#error("AGY-Mac is an Intel x86_64 app. Build with --arch x86_64.")
#endif
@main @MainActor struct AGYMacApp {
    private static var delegate: AppDelegate?
    static func main() {
        let app = NSApplication.shared
        let owner = AppDelegate(); delegate = owner; app.delegate = owner
        app.setActivationPolicy(.regular)
        app.run()
    }
}
#else
import Foundation
@main struct UnsupportedHost { static func main() { print("AGY-Mac GUI requires Intel macOS 13 or later. Core tests can run on Linux.") } }
#endif
