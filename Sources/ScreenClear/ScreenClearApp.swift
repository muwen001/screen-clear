import SwiftUI

@main
struct ScreenClearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // 自检模式：不启动 UI，输出检查结果后退出（供自动化验证使用）
        if CommandLine.arguments.contains("--selftest") {
            print(SelfTest.run())
            exit(0)
        }
        // 命令行切换模式：--apply <渲染像素>，如 2560x1440（1280×720@2x）或 1920x1080（1x）
        if let idx = CommandLine.arguments.firstIndex(of: "--apply"), idx + 1 < CommandLine.arguments.count {
            let spec = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                let report = await SelfTest.applyMode(spec)
                print(report)
                exit(report.hasPrefix("OK") ? 0 : 1)
            }
            RunLoop.main.run()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(model)
        } label: {
            MenuBarIconLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}
