import CoreGraphics
import Foundation

/// 显示器的枚举与模式切换（全部 CG 调用集中在 MainActor，视图层只见值类型）
@MainActor
enum DisplayManager {
    static func activeDisplays() -> [DisplayInfo] {
        // 用 Online 列表：CGGetActiveDisplayList 在显示器休眠时返回空（已知怪癖）
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let all = allModes(for: id)
            // 原生分辨率 = 像素面积最大的模式
            let native = all.max {
                $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
            }
            let (wMM, hMM) = RegistryReader.physicalSizeMM(
                vendorID: Int(CGDisplayVendorNumber(id)),
                productID: Int(CGDisplayModelNumber(id))
            )
            let name: String
            if CGDisplayIsBuiltin(id) == 1 {
                name = "内置显示器"
            } else {
                name = RegistryReader.productName(
                    vendorID: Int(CGDisplayVendorNumber(id)),
                    productID: Int(CGDisplayModelNumber(id))
                ) ?? "外接显示器"
            }
            return DisplayInfo(
                id: id,
                name: name,
                isBuiltin: CGDisplayIsBuiltin(id) == 1,
                vendorID: Int(CGDisplayVendorNumber(id)),
                productID: Int(CGDisplayModelNumber(id)),
                nativePixelWidth: native.map { Int($0.pixelWidth) } ?? Int(mode.pixelWidth),
                nativePixelHeight: native.map { Int($0.pixelHeight) } ?? Int(mode.pixelHeight),
                physicalWidthMM: wMM,
                physicalHeightMM: hMM
            )
        }
    }

    /// 全部模式（含被隐藏的 HiDPI 重复项）
    static func allModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else {
            return []
        }
        return modes
    }

    static func modeEntries(for displayID: CGDirectDisplayID) -> [ModeEntry] {
        let current = CGDisplayCopyDisplayMode(displayID)
        var seen = Set<String>()
        var entries: [ModeEntry] = []
        for mode in allModes(for: displayID) {
            let w = Int(mode.width), h = Int(mode.height)
            let pw = Int(mode.pixelWidth), ph = Int(mode.pixelHeight)
            let entry = ModeEntry(
                logicalWidth: w,
                logicalHeight: h,
                pixelWidth: pw,
                pixelHeight: ph,
                refreshRate: mode.refreshRate,
                isHiDPI: pw != w,
                isCurrent: false
            )
            // 去重：同一 (逻辑尺寸, 渲染尺寸, 刷新率, HiDPI) 只保留一条
            guard seen.insert(entry.id).inserted else { continue }
            let isCurrent: Bool
            if let current {
                // 当前模式判定需同时匹配逻辑尺寸与渲染尺寸（否则 1x/2x 同像素模式会同时命中）
                isCurrent = Int(current.width) == w
                    && Int(current.height) == h
                    && Int(current.pixelWidth) == pw
                    && Int(current.pixelHeight) == ph
                    && abs(current.refreshRate - mode.refreshRate) < 0.1
            } else {
                isCurrent = false
            }
            entries.append(
                ModeEntry(
                    logicalWidth: w,
                    logicalHeight: h,
                    pixelWidth: pw,
                    pixelHeight: ph,
                    refreshRate: mode.refreshRate,
                    isHiDPI: pw != w,
                    isCurrent: isCurrent
                )
            )
        }
        return entries
    }

    /// 显示器的 windowserver UUID（CGDisplayCreateUUIDFromDisplayID 为私有 API，经 dlsym 调用）
    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        typealias UUIDFunc = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateUUIDFromDisplayID") else {
            return nil
        }
        let fn = unsafeBitCast(symbol, to: UUIDFunc.self)
        guard let uuid = fn(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func isMirrored(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsInMirrorSet(displayID) == 1
    }

    static func connectionType(_ displayID: CGDirectDisplayID) -> String {
        RegistryReader.connectionType(
            vendorID: Int(CGDisplayVendorNumber(displayID)),
            productID: Int(CGDisplayModelNumber(displayID))
        )
    }

    // MARK: - 模式切换

    enum SwitchResult: Sendable {
        case succeeded(permanent: Bool)
        case failed(String)
    }

    /// 切换模式并持久化：配置批次 API（.permanently），失败回退 app-only 直接设置。
    /// 切换后 2s 校验渲染像素尺寸，不符则重试一次。
    static func apply(mode: ModeEntry, on displayID: CGDirectDisplayID) async -> SwitchResult {
        // 匹配需同时比对逻辑尺寸与渲染尺寸：1x/2x 模式渲染像素可能相同（如 960×540@2x 与 1920×1080@1x）
        guard let target = allModes(for: displayID).first(where: {
            Int($0.width) == mode.logicalWidth
                && Int($0.height) == mode.logicalHeight
                && Int($0.pixelWidth) == mode.pixelWidth
                && Int($0.pixelHeight) == mode.pixelHeight
                && abs($0.refreshRate - mode.refreshRate) < 0.5
        }) else {
            return .failed("目标模式已失效，请重新打开菜单刷新")
        }

        // 显示器休眠时切换会被系统拒绝（CGCompleteDisplayConfiguration 失败）：先唤醒
        let wake = Process()
        wake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        wake.arguments = ["-u", "-t", "1"]
        try? wake.run()
        try? await Task.sleep(nanoseconds: 600_000_000)

        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            if CGConfigureDisplayWithDisplayMode(config, displayID, target, nil) == .success {
                if CGCompleteDisplayConfiguration(config, .permanently) == .success {
                    return await verify(target, on: displayID, retry: true, permanent: true)
                }
                return .failed("持久化配置提交失败，请稍后重试")
            } else {
                CGCancelDisplayConfiguration(config)
            }
        }

        // 快速连续切换时 windowserver 可能尚未就绪：等待 1s 后重试一次配置批次
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var config2: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config2) == .success, let config2 {
            if CGConfigureDisplayWithDisplayMode(config2, displayID, target, nil) == .success {
                if CGCompleteDisplayConfiguration(config2, .permanently) == .success {
                    return await verify(target, on: displayID, retry: true, permanent: true)
                }
            } else {
                CGCancelDisplayConfiguration(config2)
            }
        }

        // 回退：当前会话直接设置（不持久化）
        if CGDisplaySetDisplayMode(displayID, target, nil) == .success {
            return await verify(target, on: displayID, retry: false, permanent: false)
        }
        return .failed("切换失败（系统拒绝该模式，请稍后再试）")
    }

    private static func verify(
        _ target: CGDisplayMode,
        on displayID: CGDirectDisplayID,
        retry: Bool,
        permanent: Bool
    ) async -> SwitchResult {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if matches(target, on: displayID) {
            return .succeeded(permanent: permanent)
        }
        if retry {
            if CGDisplaySetDisplayMode(displayID, target, nil) == .success {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if matches(target, on: displayID) {
                    return .succeeded(permanent: permanent)
                }
            }
        }
        return .failed("切换后校验未通过，模式可能被系统拒绝，请重试")
    }

    private static func matches(_ target: CGDisplayMode, on displayID: CGDirectDisplayID) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
        return current.pixelWidth == target.pixelWidth && current.pixelHeight == target.pixelHeight
    }
}
