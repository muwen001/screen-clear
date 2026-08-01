import CoreGraphics
import Foundation
import Observation

/// 应用状态与编排（@MainActor；菜单关闭时视图树销毁，状态必须放在这里）
@MainActor
@Observable
final class AppModel {
    // MARK: - 展示状态

    var externalDisplay: DisplayInfo?
    var modes: [ModeEntry] = []
    var statusMessage = ""
    var statusIsError = false
    var isBusy = false
    var overrideInstalled = false
    var overridePending = false
    var linkPatched = false

    // MARK: - 预设

    enum Preset: String, CaseIterable, Identifiable {
        case standard, balanced, spacious, crisp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: "标准尺寸（推荐）"
            case .balanced: "均衡（字更大）"
            case .spacious: "更多空间（字更小）"
            case .crisp: "清晰优先（字最大）"
            }
        }
        var detail: String {
            switch self {
            case .standard: "1920×1080 @2x · 渲染 3840×2160 降采样 · 布局与现在一致，最清晰"
            case .balanced: "1440×810 @2x · 渲染 2880×1620 降采样"
            case .spacious: "1600×900 @2x · 渲染 3200×1800 降采样"
            case .crisp: "1280×720 @2x · 原生点对点，最锐利"
            }
        }
        var logicalSize: (w: Int, h: Int) {
            switch self {
            case .standard: (1920, 1080)
            case .balanced: (1440, 810)
            case .spacious: (1600, 900)
            case .crisp: (1280, 720)
            }
        }
    }

    private var lastSwitchAt = Date.distantPast

    // MARK: - 刷新

    func refresh() {
        let displays = DisplayManager.activeDisplays()
        externalDisplay = displays.first { !$0.isBuiltin }
        modes = externalDisplay.map { DisplayManager.modeEntries(for: $0.id) } ?? []
        overrideInstalled = OverrideInstaller.isInstalled()
        linkPatched = LinkDescriptionPatcher.isPatched()
        if let display = externalDisplay, DisplayManager.isMirrored(display.id) {
            setStatus("警告：外接屏处于镜像模式，切换可能牵动整组显示器", error: true)
        }
    }

    // MARK: - 模式切换

    func presetMode(_ preset: Preset) -> ModeEntry? {
        let s = preset.logicalSize
        return modes.first { $0.isHiDPI && $0.logicalWidth == s.w && $0.logicalHeight == s.h }
    }

    func applyPreset(_ preset: Preset) {
        guard let display = externalDisplay else {
            setStatus("未检测到外接显示器", error: true)
            return
        }
        guard !isBusy else { return }
        guard let mode = presetMode(preset) else {
            setStatus("「\(preset.title)」尚未解锁——先点下方「解锁中档 HiDPI」", error: true)
            return
        }
        switchMode(mode, displayID: display.id)
    }

    func applyMode(_ mode: ModeEntry) {
        guard let display = externalDisplay else {
            setStatus("未检测到外接显示器", error: true)
            return
        }
        guard !isBusy else { return }
        switchMode(mode, displayID: display.id)
    }

    private func switchMode(_ mode: ModeEntry, displayID: CGDirectDisplayID) {
        isBusy = true
        setStatus("正在切换为 \(mode.logicalWidth)×\(mode.logicalHeight)…", error: false)
        Task {
            // 连续切换节流：两次之间至少间隔 1.5s
            let since = Date().timeIntervalSince(lastSwitchAt)
            if since < 1.5 {
                try? await Task.sleep(nanoseconds: UInt64((1.5 - since) * 1_000_000_000))
            }
            let result = await DisplayManager.apply(mode: mode, on: displayID)
            lastSwitchAt = Date()
            isBusy = false
            switch result {
            case .succeeded(let permanent):
                setStatus(
                    permanent
                        ? "已切换为 \(mode.logicalWidth)×\(mode.logicalHeight) ✓（重启后保持）"
                        : "已切换为 \(mode.logicalWidth)×\(mode.logicalHeight) ✓（当前会话）",
                    error: false
                )
            case .failed(let message):
                setStatus(message, error: true)
            }
            refresh()
        }
    }

    // MARK: - 解锁中档 HiDPI（B1）

    private let renderResolutions: [(pixelWidth: Int, pixelHeight: Int)] = [
        (3840, 2160),   // 1920×1080 @2x（标准尺寸，布局与 1x 1080p 一致）
        (2880, 1620),   // 1440×810 @2x
        (3200, 1800),   // 1600×900 @2x
    ]

    func installOverride() {
        guard !isBusy else { return }
        switch OverrideBuilder.buildPlist(renderResolutions: renderResolutions) {
        case .failure(let message):
            setStatus(message, error: true)
        case .success(let xml):
            isBusy = true
            setStatus("请在弹窗中输入管理员密码以写入解锁配置…", error: false)
            Task {
                let result = await OverrideInstaller.install(plistXML: xml)
                isBusy = false
                switch result {
                case .failure(let message):
                    setStatus("写入失败：\(message)", error: true)
                case .success:
                    overrideInstalled = true
                    overridePending = true
                    setStatus("已写入 ✓ 正在等待新模式生效…", error: false)
                    await pollForNewModes()
                }
            }
        }
    }

    func uninstallOverride() {
        guard !isBusy else { return }
        isBusy = true
        setStatus("正在移除解锁配置（需要管理员密码）…", error: false)
        Task {
            let result = await OverrideInstaller.uninstall()
            isBusy = false
            switch result {
            case .failure(let message):
                setStatus("移除失败：\(message)", error: true)
            case .success:
                overrideInstalled = false
                overridePending = false
                setStatus("已移除 ✓ 新模式会在重插线缆或重启后消失", error: false)
            }
            refresh()
        }
    }

    /// 写入后轮询新模式：每 3s → 30s；然后让显示器休眠唤醒重握手 → 2 分钟；仍未生效提示重插/重启
    private func pollForNewModes() async {
        guard let display = externalDisplay else { return }
        let targets: Set<String> = ["3840x2160", "2880x1620", "3200x1800"]
        func hasNewModes() -> Bool {
            let px = DisplayManager.modeEntries(for: display.id).map { "\($0.pixelWidth)x\($0.pixelHeight)" }
            return !Set(px).isDisjoint(with: targets)
        }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if hasNewModes() {
                finishPolling(message: "新模式已出现 ✓ 现在可以直接切换「均衡」或「更多空间」")
                return
            }
        }
        setStatus("未检测到新模式：让显示器休眠再唤醒（HDMI 重握手会重新读取配置），请稍候…", error: false)
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        try? pmset.run()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if hasNewModes() {
                finishPolling(message: "新模式已出现 ✓（显示器重握手后生效）现在可以直接切换「均衡」或「更多空间」")
                return
            }
            if CGDisplayIsAsleep(display.id) == 0 {
                // 已被唤醒，继续轮询
            }
        }
        finishPolling(
            message: "仍未生效：请拔下 HDMI 线再插回（数秒内生效）；若仍不行请重启 Mac",
            pending: true
        )
    }

    private func finishPolling(message: String, pending: Bool = false) {
        overridePending = pending
        setStatus(message, error: false)
        refresh()
    }

    // MARK: - 颜色修复（B2）

    func applyLinkDescription() {
        guard let display = externalDisplay else {
            setStatus("未检测到外接显示器", error: true)
            return
        }
        guard !isBusy else { return }
        let uuid = DisplayManager.uuidString(for: display.id)
        let current = modes.first { $0.isCurrent }
        let fallback = current.map { (w: $0.logicalWidth, h: $0.logicalHeight, isHiDPI: $0.isHiDPI) }
        isBusy = true
        setStatus("正在写入 LinkDescription（ByHost，免管理员）…", error: false)
        Task {
            let result = LinkDescriptionPatcher.applyToByHost(uuid: uuid, fallback: fallback)
            isBusy = false
            switch result {
            case .success(let message):
                linkPatched = true
                setStatus(message, error: false)
            case .failure(let message):
                setStatus(message, error: true)
            }
        }
    }

    func restoreLinkDescription() {
        guard !isBusy else { return }
        isBusy = true
        setStatus("正在恢复…", error: false)
        Task {
            let result = LinkDescriptionPatcher.restoreByHost()
            isBusy = false
            switch result {
            case .success(let message):
                linkPatched = LinkDescriptionPatcher.isPatched()
                setStatus(message, error: false)
            case .failure(let message):
                setStatus(message, error: true)
            }
        }
    }

    func applyLinkDescriptionSystem() {
        guard let display = externalDisplay else {
            setStatus("未检测到外接显示器", error: true)
            return
        }
        guard !isBusy else { return }
        let uuid = DisplayManager.uuidString(for: display.id)
        let current = modes.first { $0.isCurrent }
        let fallback = current.map { (w: $0.logicalWidth, h: $0.logicalHeight, isHiDPI: $0.isHiDPI) }
        isBusy = true
        setStatus("正在写入系统级 LinkDescription（需要管理员密码）…", error: false)
        Task {
            let result = await LinkDescriptionPatcher.applyToSystem(uuid: uuid, fallback: fallback)
            isBusy = false
            switch result {
            case .success(let message):
                linkPatched = LinkDescriptionPatcher.isPatched()
                setStatus(message, error: false)
            case .failure(let message):
                setStatus(message, error: true)
            }
        }
    }

    func restoreLinkDescriptionSystem() {
        guard !isBusy else { return }
        isBusy = true
        setStatus("正在恢复系统级配置（需要管理员密码）…", error: false)
        Task {
            let result = await LinkDescriptionPatcher.restoreSystem()
            isBusy = false
            switch result {
            case .success(let message):
                linkPatched = LinkDescriptionPatcher.isPatched()
                setStatus(message, error: false)
            case .failure(let message):
                setStatus(message, error: true)
            }
        }
    }

    // MARK: - 开机自启（LaunchAgent）

    var launchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    private var launchAgentPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/local.screenclear.plist"
    }

    func toggleLaunchAgent() {
        if launchAgentInstalled {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
            setStatus("已关闭开机自启", error: false)
            return
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>local.screenclear</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        do {
            try xml.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } catch {
            setStatus("写入 LaunchAgent 失败：\(error.localizedDescription)", error: true)
            return
        }
        // 立即在当前会话加载（失败则下次登录生效）
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", "gui/\(getuid())", launchAgentPath]
        try? bootstrap.run()
        setStatus("已开启开机自启 ✓", error: false)
    }

    // MARK: - 工具

    func setStatus(_ message: String, error: Bool) {
        statusMessage = message
        statusIsError = error
    }
}
