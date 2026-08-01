import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 无 Info.plist 的裸可执行文件：在此处（而非 App.init）设置 accessory 策略，
        // 避免 Dock 图标闪现；此时 NSApp 已可用。
        NSApp.setActivationPolicy(.accessory)
    }
}
