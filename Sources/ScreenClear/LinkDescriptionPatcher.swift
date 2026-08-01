import Foundation

/// 颜色修复：在 windowserver 的 displays plist 中写入 LinkDescription，
/// 强制 M 系列外接显示器走 RGB 全范围输出（修复发灰泛白）。
/// 参考: https://gist.github.com/GetVladimir/c89a26df1806001543bef4c8d90cc2f8
/// 注意：macOS 13.3+ 重启后可能被系统覆盖，属"尽力而为"，提供备份恢复。
enum LinkDescriptionPatcher {
    /// 计算属性（每次返回新字典，避免静态存储的 Sendable 检查）
    static var linkDescription: [String: Any] {
        [
            "BitDepth": 8,
            "EOTF": 0,
            "PixelEncoding": 0,
            "Range": 1,
        ]
    }

    private static let byHostSetsKey = "DisplaySets"
    private static let systemSetsKey = "DisplayAnyUserSets"

    static var backupDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ScreenClear/Backups", isDirectory: true)
    }

    static func byHostPath() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Preferences/ByHost"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files
            .filter { $0.hasPrefix("com.apple.windowserver.displays.") && $0.hasSuffix(".plist") }
            .sorted()
            .first
            .map { dir + "/" + $0 }
    }

    static func isPatched() -> Bool {
        if let path = byHostPath(), plistHasLinkDescription(path) { return true }
        return plistHasLinkDescription("/Library/Preferences/com.apple.windowserver.displays.plist")
    }

    // MARK: - ByHost（免管理员）

    static func applyToByHost(uuid: String?, fallback: (w: Int, h: Int, isHiDPI: Bool)?) -> Result<String, String> {
        guard let path = byHostPath() else {
            return .failure("未找到 ByHost 显示配置文件")
        }
        do {
            let patched = try apply(filePath: path, uuid: uuid, fallbackLogical: fallback)
            if patched {
                return .success("已写入 ByHost LinkDescription ✓ 重启后生效；可随时一键恢复")
            }
            return .failure("ByHost 配置中未找到外接屏条目（UUID: \(uuid ?? "未知")）")
        } catch {
            return .failure("写入失败：\(error.localizedDescription)")
        }
    }

    static func restoreByHost() -> Result<String, String> {
        guard let path = byHostPath() else { return .failure("未找到 ByHost 配置") }
        if restore(filePath: path) {
            return .success("已从备份恢复 ByHost 配置 ✓ 重启后生效")
        }
        do {
            guard let root = readMutable(path) else { return .failure("无法读取 ByHost 配置") }
            removeLinkDescription(root)
            try write(root, to: path)
            return .success("已移除 LinkDescription ✓ 重启后生效")
        } catch {
            return .failure("恢复失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 系统级（需管理员）

    static func applyToSystem(uuid: String?, fallback: (w: Int, h: Int, isHiDPI: Bool)?) async -> Result<String, String> {
        let systemPath = "/Library/Preferences/com.apple.windowserver.displays.plist"
        guard FileManager.default.fileExists(atPath: systemPath) else {
            return .failure("系统级显示配置文件不存在")
        }
        do {
            guard let root = readMutable(systemPath) else { return .failure("无法读取系统级配置") }
            try backup(systemPath)
            let patched = applyTo(root: root, uuid: uuid, fallbackLogical: fallback)
            guard patched else { return .failure("系统配置中未找到外接屏条目") }
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            let tmp = "/tmp/screenclear-system-\(ProcessInfo.processInfo.processIdentifier).plist"
            try data.write(to: URL(fileURLWithPath: tmp))
            let script = """
            do shell script "cp '\(tmp)' '\(systemPath)' && chown root:wheel '\(systemPath)' && chmod 644 '\(systemPath)'" \
            with administrator privileges
            """
            let result = await OverrideInstaller.runOSAScript(script)
            try? FileManager.default.removeItem(atPath: tmp)
            switch result {
            case .success:
                return .success("已写入系统级 LinkDescription ✓ 重启后生效")
            case .failure(let message):
                return .failure(message)
            }
        } catch {
            return .failure("写入失败：\(error.localizedDescription)")
        }
    }

    static func restoreSystem() async -> Result<String, String> {
        let systemPath = "/Library/Preferences/com.apple.windowserver.displays.plist"
        let name = URL(fileURLWithPath: systemPath).lastPathComponent + ".bak"
        let backup = backupDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: backup.path) else {
            return .failure("没有系统级备份，无法恢复")
        }
        let script = """
        do shell script "cp '\(backup.path)' '\(systemPath)' && chown root:wheel '\(systemPath)' && chmod 644 '\(systemPath)'" \
        with administrator privileges
        """
        let result = await OverrideInstaller.runOSAScript(script)
        switch result {
        case .success: return .success("已从备份恢复系统级配置 ✓ 重启后生效")
        case .failure(let message): return .failure(message)
        }
    }

    // MARK: - 内部实现

    private static func readMutable(_ path: String) -> NSMutableDictionary? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainers], format: nil
        )
        return plist as? NSMutableDictionary
    }

    private static func write(_ root: NSMutableDictionary, to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func allConfigArrays(_ root: NSMutableDictionary) -> [NSMutableArray] {
        var arrays: [NSMutableArray] = []
        for key in [byHostSetsKey, systemSetsKey] {
            guard let sets = root[key] as? NSMutableDictionary,
                  let configs = sets["Configs"] as? NSMutableArray else { continue }
            for case let config as NSMutableDictionary in configs {
                if let dc = config["DisplayConfig"] as? NSMutableArray {
                    arrays.append(dc)
                }
            }
        }
        return arrays
    }

    /// 在文件副本上打补丁并写回；返回是否找到外接屏条目
    static func apply(
        filePath: String,
        uuid: String?,
        fallbackLogical: (w: Int, h: Int, isHiDPI: Bool)?
    ) throws -> Bool {
        guard let root = readMutable(filePath) else { throw CocoaError(.fileReadUnknown) }
        try backup(filePath)
        guard applyTo(root: root, uuid: uuid, fallbackLogical: fallbackLogical) else { return false }
        try write(root, to: filePath)
        return true
    }

    /// 在已加载的 plist 上打补丁：匹配 UUID 或 CurrentInfo 分辨率的外接屏条目
    private static func applyTo(
        root: NSMutableDictionary,
        uuid: String?,
        fallbackLogical: (w: Int, h: Int, isHiDPI: Bool)?
    ) -> Bool {
        var patched = false
        let link = linkDescription as NSDictionary
        for configArray in allConfigArrays(root) {
            for case let entry as NSMutableDictionary in configArray {
                let uuidMatches = uuid != nil && (entry["UUID"] as? String) == uuid
                let dimsMatch: Bool
                if let f = fallbackLogical, let info = entry["CurrentInfo"] as? NSDictionary {
                    let w = info["Wide"] as? Int
                    let h = info["High"] as? Int
                    let scale = info["Scale"] as? Int
                    dimsMatch = (w == f.w && h == f.h && (f.isHiDPI ? scale == 2 : scale == 1))
                } else {
                    dimsMatch = false
                }
                if uuidMatches || dimsMatch {
                    entry["LinkDescription"] = link
                    (entry["CurrentInfo"] as? NSMutableDictionary)?["LinkDescription"] = link
                    patched = true
                }
            }
        }
        return patched
    }

    private static func removeLinkDescription(_ root: NSMutableDictionary) {
        for configArray in allConfigArrays(root) {
            for case let entry as NSMutableDictionary in configArray {
                entry.removeObject(forKey: "LinkDescription")
                (entry["CurrentInfo"] as? NSMutableDictionary)?.removeObject(forKey: "LinkDescription")
            }
        }
    }

    private static func plistHasLinkDescription(_ path: String) -> Bool {
        guard let root = readMutable(path) else { return false }
        for configArray in allConfigArrays(root) {
            for case let entry as NSMutableDictionary in configArray {
                if entry["LinkDescription"] != nil { return true }
                if let info = entry["CurrentInfo"] as? NSDictionary, info["LinkDescription"] != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func backup(_ filePath: String) throws {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let dest = backupDir.appendingPathComponent(URL(fileURLWithPath: filePath).lastPathComponent + ".bak")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(atPath: filePath, toPath: dest.path)
        }
    }

    private static func restore(filePath: String) -> Bool {
        let backup = backupDir.appendingPathComponent(URL(fileURLWithPath: filePath).lastPathComponent + ".bak")
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        do {
            try? FileManager.default.removeItem(atPath: filePath)
            try FileManager.default.copyItem(atPath: backup.path, toPath: filePath)
            return true
        } catch {
            return false
        }
    }
}
