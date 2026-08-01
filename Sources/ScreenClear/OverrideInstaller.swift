import Foundation

/// 通过 osascript 管理员授权安装/移除 /Library/Displays override 文件。
/// 无签名 app 在 macOS 13+ 上无法使用 SMAppService，osascript 是可行路径。
enum OverrideInstaller {
    static func configurationState(
        atPath path: String = OverrideBuilder.targetFile
    ) -> OverrideConfigurationState {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return OverrideBuilder.configurationState(for: data)
        } catch {
            return .invalid("读取 override 失败：\(error.localizedDescription)")
        }
    }

    static func existingData(
        atPath path: String = OverrideBuilder.targetFile
    ) -> Result<Data?, String> {
        guard FileManager.default.fileExists(atPath: path) else {
            return .success(nil)
        }
        do {
            return .success(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            return .failure("读取 override 失败：\(error.localizedDescription)")
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func privilegedInstallCommand(
        sourcePath: String,
        targetDirectory: String,
        targetFile: String,
        token: String
    ) -> String {
        let stage = targetFile + ".screenclear-" + token
        return [
            "set -e",
            "stage=\(shellQuote(stage))",
            "cleanup() { /bin/rm -f \"$stage\"; }",
            "trap cleanup EXIT HUP INT TERM",
            "/bin/mkdir -p \(shellQuote(targetDirectory))",
            "/bin/cp \(shellQuote(sourcePath)) \"$stage\"",
            "/usr/bin/plutil -lint \"$stage\" >/dev/null",
            "/bin/chmod 0644 \"$stage\"",
            "/bin/mv -f \"$stage\" \(shellQuote(targetFile))",
            "trap - EXIT HUP INT TERM",
        ].joined(separator: "; ")
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func install(plistXML: String) async -> Result<Void, String> {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screenclear-override-\(UUID().uuidString)",
                isDirectory: true
            )
        let source = root.appendingPathComponent("override.plist")
        var ownsRoot = false
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            ownsRoot = true
            try plistXML.write(to: source, atomically: true, encoding: .utf8)
        } catch {
            if ownsRoot {
                try? FileManager.default.removeItem(at: root)
            }
            return .failure("写入临时 override 失败：\(error.localizedDescription)")
        }
        defer {
            if ownsRoot {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let command = privilegedInstallCommand(
            sourcePath: source.path,
            targetDirectory: OverrideBuilder.targetDir,
            targetFile: OverrideBuilder.targetFile,
            token: UUID().uuidString
        )
        let script = "do shell script \(appleScriptStringLiteral(command)) "
            + "with administrator privileges"
        return await runOSAScript(script)
    }

    static func uninstall() async -> Result<Void, String> {
        let script = """
        do shell script "rm -f '\(OverrideBuilder.targetFile)' && rmdir '\(OverrideBuilder.targetDir)' 2>/dev/null; true" \
        with administrator privileges
        """
        return await runOSAScript(script)
    }

    /// 运行 osascript（管理员弹窗），等待用户授权/取消
    static func runOSAScript(_ script: String) async -> Result<Void, String> {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    return .success(())
                }
                let detail = message.isEmpty ? "退出码 \(process.terminationStatus)" : message
                return .failure(detail)
            } catch {
                return .failure("无法启动 osascript: \(error.localizedDescription)")
            }
        }.value
    }
}
