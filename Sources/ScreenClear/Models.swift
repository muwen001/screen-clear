import CoreGraphics
import Foundation

/// 显示器信息（仅值类型，视图层可安全使用）
struct DisplayInfo: Identifiable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let vendorID: Int
    let productID: Int
    let nativePixelWidth: Int
    let nativePixelHeight: Int
    let physicalWidthMM: Int
    let physicalHeightMM: Int

    /// 像素密度（基于显示器物理宽度）
    var ppi: Double? {
        guard physicalWidthMM > 0, nativePixelWidth > 0 else { return nil }
        return Double(nativePixelWidth) / (Double(physicalWidthMM) / 25.4)
    }
}

/// 单个显示模式（逻辑分辨率 + 渲染像素）
struct ModeEntry: Identifiable, Sendable {
    var id: String {
        "\(logicalWidth)x\(logicalHeight):\(pixelWidth)x\(pixelHeight)@\(Int(refreshRate))x\(isHiDPI ? "2" : "1")"
    }
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let isCurrent: Bool

    func matchesConfiguration(
        of other: ModeEntry,
        refreshRateTolerance: Double = 0.1
    ) -> Bool {
        logicalWidth == other.logicalWidth
            && logicalHeight == other.logicalHeight
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && abs(refreshRate - other.refreshRate) < refreshRateTolerance
    }
}
