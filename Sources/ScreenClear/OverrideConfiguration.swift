import Foundation

extension OverrideBuilder {
    static let activationModes = managedModes.filter {
        ($0.logicalWidth == 1920 && $0.logicalHeight == 1080)
            || ($0.logicalWidth == 2560 && $0.logicalHeight == 1440)
    }

    private static func parsedRoot(from data: Data) -> Result<[String: Any], String> {
        do {
            guard let root = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any] else {
                return .failure("override plist 根对象不是字典")
            }
            guard root["DisplayVendorID"] as? Int == vendorID,
                  root["DisplayProductID"] as? Int == productID else {
                return .failure("override 显示器标识不匹配")
            }
            guard root["scale-resolutions"] is [Data] else {
                return .failure("scale-resolutions 不是 data 数组")
            }
            return .success(root)
        } catch {
            return .failure("解析 override plist 失败：\(error.localizedDescription)")
        }
    }

    static func configurationState(for data: Data) -> OverrideConfigurationState {
        switch parsedRoot(from: data) {
        case .failure(let reason):
            return .invalid(reason)
        case .success(let root):
            guard let entries = root["scale-resolutions"] as? [Data] else {
                return .invalid("scale-resolutions 不是 data 数组")
            }
            return Set(managedEntryData).isSubset(of: Set(entries))
                ? .current
                : .outdated
        }
    }

    static func buildManagedPlist(existingData: Data?) -> Result<String, String> {
        var root: [String: Any]
        if let existingData {
            switch parsedRoot(from: existingData) {
            case .failure(let reason):
                return .failure(reason)
            case .success(let parsed):
                root = parsed
            }
        } else {
            root = [
                "DisplayVendorID": vendorID,
                "DisplayProductID": productID,
                "scale-resolutions": [Data](),
            ]
        }

        guard let existing = root["scale-resolutions"] as? [Data] else {
            return .failure("scale-resolutions 不是 data 数组")
        }
        var seen = Set<Data>()
        var merged = existing.filter { seen.insert($0).inserted }
        for entry in managedEntryData where seen.insert(entry).inserted {
            merged.append(entry)
        }
        root["scale-resolutions"] = merged

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: .xml,
                options: 0
            )
            guard let xml = String(data: data, encoding: .utf8) else {
                return .failure("生成的 plist 不是 UTF-8")
            }
            return .success(xml)
        } catch {
            return .failure("生成 plist 失败：\(error.localizedDescription)")
        }
    }

    static func activationModesPresent(in modes: [ModeEntry]) -> Bool {
        activationModes.allSatisfy { requirement in
            modes.contains(where: requirement.matches)
        }
    }
}
