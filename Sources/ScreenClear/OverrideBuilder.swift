import Foundation

/// 生成写入 /Library/Displays/Contents/Resources/Overrides 的 plist，
/// 通过 scale-resolutions 解锁 2K 屏的中档 HiDPI 模式（渲染 2x 后降采样）。
/// 格式与 one-key-hidpi 完全一致：base64(4B 大端渲染宽, 4B 大端渲染高, 0x00)。
enum OverrideBuilder {
    static let vendorID = 1507           // 0x5e3 (AOC)
    static let productID = 9360          // 0x2490 (Q2490W1)
    static var vendorHex: String { String(vendorID, radix: 16) }
    static var productHex: String { String(productID, radix: 16) }
    static var targetDir: String {
        "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-\(vendorHex)"
    }
    static var targetFile: String { "\(targetDir)/DisplayProductID-\(productHex)" }

    static func scaleEntry(pixelWidth: Int, pixelHeight: Int) -> String {
        var bytes: [UInt8] = [
            UInt8((pixelWidth >> 24) & 0xFF), UInt8((pixelWidth >> 16) & 0xFF),
            UInt8((pixelWidth >> 8) & 0xFF), UInt8(pixelWidth & 0xFF),
            UInt8((pixelHeight >> 24) & 0xFF), UInt8((pixelHeight >> 16) & 0xFF),
            UInt8((pixelHeight >> 8) & 0xFF), UInt8(pixelHeight & 0xFF),
        ]
        bytes.append(0x00)
        return Data(bytes).base64EncodedString()
    }

    /// base64 往返自检：解码结果必须与原始渲染尺寸一致
    static func verifyEntry(_ entry: String, pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard let data = Data(base64Encoded: entry), data.count == 9 else { return false }
        let w = (Int(data[0]) << 24) | (Int(data[1]) << 16) | (Int(data[2]) << 8) | Int(data[3])
        let h = (Int(data[4]) << 24) | (Int(data[5]) << 16) | (Int(data[6]) << 8) | Int(data[7])
        return w == pixelWidth && h == pixelHeight && data[8] == 0
    }

    static func buildPlist(renderResolutions: [(pixelWidth: Int, pixelHeight: Int)]) -> Result<String, String> {
        var entries: [String] = []
        for res in renderResolutions {
            let entry = scaleEntry(pixelWidth: res.pixelWidth, pixelHeight: res.pixelHeight)
            guard verifyEntry(entry, pixelWidth: res.pixelWidth, pixelHeight: res.pixelHeight) else {
                return .failure("scale-resolutions 条目编码自检失败: \(res.pixelWidth)x\(res.pixelHeight)")
            }
            entries.append(entry)
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DisplayProductID</key>
            <integer>\(productID)</integer>
            <key>DisplayVendorID</key>
            <integer>\(vendorID)</integer>
            <key>scale-resolutions</key>
            <array>
        """
        for entry in entries {
            xml += "        <data>\(entry)</data>\n"
        }
        xml += """
            </array>
        </dict>
        </plist>
        """
        return .success(xml)
    }
}
