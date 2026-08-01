import Foundation

/// 通过 osascript 管理员授权安装/移除 /Library/Displays override 文件。
/// 无签名 app 在 macOS 13+ 上无法使用 SMAppService，osascript 是可行路径。
enum OverrideInstaller {
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: OverrideBuilder.targetFile)
    }

    static func install(plistXML: String) async -> Result<Void, String> {
        let tmp = "/tmp/screenclear-\(ProcessInfo.processInfo.processIdentifier).plist"
        do {
            try plistXML.write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .failure("写入临时文件失败: \(error.localizedDescription)")
        }
        let script = """
        do shell script "mkdir -p '\(OverrideBuilder.targetDir)' && cp '\(tmp)' '\(OverrideBuilder.targetFile)'" \
        with administrator privileges
        """
        let result = await runOSAScript(script)
        try? FileManager.default.removeItem(atPath: tmp)
        return result
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
