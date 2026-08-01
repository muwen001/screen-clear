import AppKit
import SwiftUI

/// 菜单内容：只用 Button/Text/Divider（.menu 样式 + accessory 策略的稳定组合）
struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            infoSection
            Divider()
            presetsSection
            Divider()
            modesSection
            Divider()
            toolsSection
            if !model.statusMessage.isEmpty {
                Divider()
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            Button("退出 ScreenClear") {
                NSApp.terminate(nil)
            }
        }
        .onAppear { model.refresh() }
    }

    // MARK: - 信息区

    @ViewBuilder
    private var infoSection: some View {
        if let display = model.externalDisplay {
            Text(display.name + "（外接）")
                .font(.headline)
            Text(buildInfoLine(display))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let current = model.modes.first(where: { $0.isCurrent }) {
                Text("当前：\(current.logicalWidth)×\(current.logicalHeight)\(current.isHiDPI ? " @2x HiDPI" : " @1x") · \(String(format: "%.0f Hz", current.refreshRate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("未检测到外接显示器")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("刷新") { model.refresh() }
            .font(.caption)
    }

    private func buildInfoLine(_ display: DisplayInfo) -> String {
        var parts: [String] = []
        parts.append("原生 \(display.nativePixelWidth)×\(display.nativePixelHeight)")
        if let ppi = display.ppi {
            parts.append(String(format: "%.0f PPI", ppi))
        }
        parts.append(DisplayManager.connectionType(display.id))
        return parts.joined(separator: " · ")
    }

    // MARK: - 预设

    @ViewBuilder
    private var presetsSection: some View {
        ForEach(AppModel.Preset.allCases) { preset in
            let available = model.presetMode(preset) != nil
            Button {
                model.applyPreset(preset)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                    Text(preset.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!available || model.isBusy)
            if !available && preset == .crisp {
                // 只在清晰优先不可用时给出提示（原生档不可能缺失，兜底文案）
                Text("提示：HiDPI 模式列表为空，请点击「刷新」")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 模式列表

    @ViewBuilder
    private var modesSection: some View {
        let list = model.modes
            .sorted { lhs, rhs in
                if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
                return lhs.pixelWidth * lhs.pixelHeight > rhs.pixelWidth * rhs.pixelHeight
            }
            .prefix(12)
        if !model.modes.isEmpty {
            Text("其他可用模式")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(list) { mode in
                if mode.isCurrent {
                    Text("✓ \(mode.logicalWidth)×\(mode.logicalHeight)\(mode.isHiDPI ? " @2x" : " @1x")（当前）\(refreshSuffix(mode))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.applyMode(mode)
                    } label: {
                        Text("\(mode.logicalWidth)×\(mode.logicalHeight)\(mode.isHiDPI ? " @2x" : " @1x")\(refreshSuffix(mode))")
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private func refreshSuffix(_ mode: ModeEntry) -> String {
        mode.refreshRate > 0 ? " · \(String(format: "%.0f Hz", mode.refreshRate))" : ""
    }

    // MARK: - 工具区

    @ViewBuilder
    private var toolsSection: some View {
        Text("工具")
            .font(.caption)
            .foregroundStyle(.secondary)
        switch model.overrideConfigurationState {
        case .missing:
            Button("解锁 HiDPI（需管理员密码）") {
                model.installOrUpdateOverride()
            }
            .disabled(model.isBusy)
        case .outdated:
            Button("更新 HiDPI 配置（新增 1080p / 1440p @2x，需管理员密码）") {
                model.installOrUpdateOverride()
            }
            .disabled(model.isBusy)
        case .current:
            if model.overridePending {
                Text("⏳ 配置已写入，正在等待 1080p / 1440p @2x…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button("✓ HiDPI 配置已是最新（点击移除）") {
                model.uninstallOverride()
            }
            .disabled(model.isBusy)
        case .invalid(let reason):
            Text("⚠️ HiDPI 配置无法安全更新：\(reason)")
                .font(.caption2)
                .foregroundStyle(.orange)
            Button("移除无效 HiDPI 配置（需管理员密码）") {
                model.uninstallOverride()
            }
            .disabled(model.isBusy)
        }
        if model.linkPatched {
            Button("✓ 颜色修复已写入（点击恢复 ByHost）") { model.restoreLinkDescription() }
                .disabled(model.isBusy)
        } else {
            Button("颜色修复：写入 LinkDescription（重启生效）") { model.applyLinkDescription() }
                .disabled(model.isBusy)
        }
        Button("系统级颜色修复（需管理员密码）") { model.applyLinkDescriptionSystem() }
            .disabled(model.isBusy)
        Button("恢复系统级颜色配置（需管理员密码）") { model.restoreLinkDescriptionSystem() }
            .disabled(model.isBusy)
        Button(model.launchAgentInstalled ? "✓ 开机自启已开启（点击关闭）" : "开启开机自启") {
            model.toggleLaunchAgent()
        }
        .disabled(model.isBusy)
    }
}
