import CoreGraphics
import Foundation

/// `--selftest` 自检：只读检查 + 纯计算验证，不修改任何系统状态、不切换模式
@MainActor
enum SelfTest {
    static func run() -> String {
        var lines: [String] = []

        // 1. 显示器枚举
        let displays = DisplayManager.activeDisplays()
        lines.append("== 显示器枚举 ==")
        for d in displays {
            let ppi = d.ppi.map { String(format: "%.0f", $0) } ?? "?"
            lines.append("  \(d.name) builtin=\(d.isBuiltin) vendor=\(d.vendorID) product=\(d.productID) native=\(d.nativePixelWidth)x\(d.nativePixelHeight) size=\(d.physicalWidthMM)x\(d.physicalHeightMM)mm PPI=\(ppi) conn=\(DisplayManager.connectionType(d.id)) uuid=\(DisplayManager.uuidString(for: d.id) ?? "?")")
        }
        guard let external = displays.first(where: { !$0.isBuiltin }) else {
            return (lines + ["FAIL: 未找到外接显示器"]).joined(separator: "\n")
        }

        // 2. 模式枚举
        let modes = DisplayManager.modeEntries(for: external.id)
        let hidpi = modes.filter(\.isHiDPI).sorted { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        let nonHiDPI = modes.filter { !$0.isHiDPI }.sorted { $0.pixelWidth * $0.pixelHeight > $1.pixelWidth * $1.pixelHeight }
        lines.append("== 模式（HiDPI \(hidpi.count) / 1x \(nonHiDPI.count)）==")
        for m in hidpi.prefix(8) {
            lines.append("  \(m.logicalWidth)x\(m.logicalHeight) @2x -> 渲染 \(m.pixelWidth)x\(m.pixelHeight)\(m.isCurrent ? " ★当前" : "")")
        }
        for m in nonHiDPI.prefix(4) {
            lines.append("  \(m.logicalWidth)x\(m.logicalHeight) @1x -> 渲染 \(m.pixelWidth)x\(m.pixelHeight)\(m.isCurrent ? " ★当前" : "")")
        }

        // 3. scale-resolutions 编码自检
        lines.append("== OverrideBuilder ==")
        let cases: [(Int, Int, String)] = [
            (2880, 1620, "AAALQAAABlQA"),
            (3200, 1800, "AAAMgAAABwgA"),
        ]
        var builderOK = true
        for (w, h, expected) in cases {
            let entry = OverrideBuilder.scaleEntry(pixelWidth: w, pixelHeight: h)
            let roundTrip = OverrideBuilder.verifyEntry(entry, pixelWidth: w, pixelHeight: h)
            let match = entry == expected
            lines.append("  \(w)x\(h): \(entry) 期望=\(expected) 往返自检=\(roundTrip) 匹配=\(match)")
            if !(roundTrip && match) { builderOK = false }
        }
        if builderOK {
            switch OverrideBuilder.buildPlist(renderResolutions: [(2880, 1620), (3200, 1800)]) {
            case .success(let xml):
                lines.append("  buildPlist OK，\(xml.count) 字符")
            case .failure(let message):
                lines.append("  buildPlist FAIL: \(message)")
                builderOK = false
            }
        }

        // 4. 物理属性
        lines.append("== RegistryReader ==")
        let (wMM, hMM) = RegistryReader.physicalSizeMM(vendorID: external.vendorID, productID: external.productID)
        let name = RegistryReader.productName(vendorID: external.vendorID, productID: external.productID) ?? "?"
        lines.append("  物理尺寸 \(wMM)x\(hMM)mm  名称=\(name)")

        // 5. LinkDescription 补丁（在临时副本上干跑，不碰真实文件）
        lines.append("== LinkDescriptionPatcher（临时副本干跑）==")
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screenclear-selftest-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        let tempFile = tempRoot.appendingPathComponent("test.plist")
        let tempBackups = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let testPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DisplaySets</key>
            <dict>
                <key>Configs</key>
                <array>
                    <dict>
                        <key>DisplayConfig</key>
                        <array>
                            <dict>
                                <key>UUID</key>
                                <string>TEST-UUID-1234</string>
                                <key>CurrentInfo</key>
                                <dict>
                                    <key>Wide</key><integer>1920</integer>
                                    <key>High</key><integer>1080</integer>
                                    <key>Scale</key><integer>1</integer>
                                </dict>
                            </dict>
                        </array>
                    </dict>
                </array>
            </dict>
        </dict>
        </plist>
        """
        var patchOK = false
        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try testPlist.write(to: tempFile, atomically: true, encoding: .utf8)
            let patched = try LinkDescriptionPatcher.apply(
                filePath: tempFile.path,
                uuid: "TEST-UUID-1234",
                fallbackLogical: nil,
                backupDirectory: tempBackups
            )
            guard patched else { throw "临时 plist 中未匹配测试 UUID" }
            patchOK = true
            lines.append("  补丁写入+匹配逻辑 OK（临时文件）")
        } catch {
            lines.append("  补丁 FAIL: \(error.localizedDescription)")
        }

        // 汇总
        let ok = builderOK && patchOK && !displays.isEmpty && !modes.isEmpty
        lines.append("== 结果: \(ok ? "PASS" : "FAIL") ==")
        return lines.joined(separator: "\n")
    }

    /// 命令行切换模式：spec 为渲染像素尺寸，如 "2560x1440"、"1920x1080"。
    /// 渲染像素相同的 1x/2x 模式同时存在时，默认优先 1x（逻辑尺寸 == 渲染尺寸）；
    /// 可用后缀显式指定："2560x1440@2x" 表示 1280×720 的 2x 模式。
    static func applyMode(_ spec: String) async -> String {
        let lower = spec.lowercased()
        let explicitHiDPI = lower.hasSuffix("@2x") || lower.hasSuffix("x2")
        let clean = lower.replacingOccurrences(of: "@2x", with: "").replacingOccurrences(of: "x2", with: "")
        let parts = clean.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return "FAIL: 无法解析 \(spec)（应为 宽x高，如 2560x1440 或 2560x1440@2x）" }
        let targetW = parts[0], targetH = parts[1]
        guard let display = DisplayManager.activeDisplays().first(where: { !$0.isBuiltin }) else {
            return "FAIL: 未找到外接显示器"
        }
        let entries = DisplayManager.modeEntries(for: display.id)
        let mode: ModeEntry?
        if explicitHiDPI {
            mode = entries.first { $0.pixelWidth == targetW && $0.pixelHeight == targetH && $0.isHiDPI }
        } else {
            mode = entries.first { $0.pixelWidth == targetW && $0.pixelHeight == targetH && !$0.isHiDPI }
                ?? entries.first { $0.pixelWidth == targetW && $0.pixelHeight == targetH }
        }
        guard let mode else {
            return "FAIL: 外接屏没有 \(targetW)x\(targetH) 的渲染模式"
        }
        let result = await DisplayManager.apply(mode: mode, on: display.id)
        switch result {
        case .succeeded(let permanent):
            let now = DisplayManager.modeEntries(for: display.id).first { $0.isCurrent }
            let nowDesc = now.map { "\($0.logicalWidth)x\($0.logicalHeight)@\($0.isHiDPI ? 2 : 1)x(渲染 \($0.pixelWidth)x\($0.pixelHeight))" } ?? "?"
            return "OK: 已切换 \(spec)（\(permanent ? "持久化" : "当前会话")），当前=\(nowDesc)"
        case .failed(let message):
            return "FAIL: \(message)"
        }
    }
}
