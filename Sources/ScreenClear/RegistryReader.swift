import CoreGraphics
import Foundation
import IOKit

/// 从 IORegistry 的 AppleCLCD2 节点读取显示器的解析后属性。
/// M 系列上不暴露 IODisplayConnect / 原始 EDID，但 DisplayAttributes 可用。
enum RegistryReader {
    private static func externalProperties(vendorID: Int, productID: Int) -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLCD2"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let props = ioProperties(service) else { continue }
            // ProductAttributes 嵌套在 DisplayAttributes 内部
            guard let attrs = props["DisplayAttributes"] as? [String: Any],
                  let pa = attrs["ProductAttributes"] as? [String: Any] else { continue }
            if (pa["LegacyManufacturerID"] as? NSNumber)?.intValue == vendorID,
               (pa["ProductID"] as? NSNumber)?.intValue == productID {
                return props
            }
        }
        return nil
    }

    private static func ioProperties(_ service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props else { return nil }
        return props.takeRetainedValue() as? [String: Any]
    }

    /// 物理尺寸（mm）。DisplayAttributes 中的 MaxHorizontalImageSize/MaxVerticalImageSize 单位为 cm。
    static func physicalSizeMM(vendorID: Int, productID: Int) -> (wMM: Int, hMM: Int) {
        guard let props = externalProperties(vendorID: vendorID, productID: productID),
              let attrs = props["DisplayAttributes"] as? [String: Any] else { return (0, 0) }
        let w = (attrs["MaxHorizontalImageSize"] as? NSNumber)?.intValue ?? 0
        let h = (attrs["MaxVerticalImageSize"] as? NSNumber)?.intValue ?? 0
        return (w * 10, h * 10)
    }

    static func productName(vendorID: Int, productID: Int) -> String? {
        guard let props = externalProperties(vendorID: vendorID, productID: productID),
              let attrs = props["DisplayAttributes"] as? [String: Any],
              let pa = attrs["ProductAttributes"] as? [String: Any] else { return nil }
        return pa["ProductName"] as? String
    }

    /// 连接类型：优先用 DisplayAttributes 的 HasHDMILegacyEDID 标记（AppleCLCD2 节点可靠持有），
    /// 其次尝试 DisplayHints 元数据（DFP Type Description 在传输层节点上，可能读不到）
    static func connectionType(vendorID: Int, productID: Int) -> String {
        guard let props = externalProperties(vendorID: vendorID, productID: productID),
              let attrs = props["DisplayAttributes"] as? [String: Any] else { return "未知" }
        if (attrs["HasHDMILegacyEDID"] as? NSNumber)?.boolValue == true {
            return "HDMI"
        }
        if let hints = props["DisplayHints"] as? [String: Any],
           let meta = hints["Metadata"] as? [String: Any],
           let type = meta["DFP Type Description"] as? String {
            return type
        }
        return "未知"
    }
}
