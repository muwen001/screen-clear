import Foundation
import XCTest
@testable import ScreenClear

final class OverrideBuilderTests: XCTestCase {
    private func plistData(
        entries: [Data],
        vendorID: Int = OverrideBuilder.vendorID,
        productID: Int = OverrideBuilder.productID,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var root = extra
        root["DisplayVendorID"] = vendorID
        root["DisplayProductID"] = productID
        root["scale-resolutions"] = entries
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
    }

    func testKnownEntriesRoundTrip() {
        let cases = [
            (2880, 1620, "AAALQAAABlQA"),
            (3200, 1800, "AAAMgAAABwgA"),
            (5120, 2880, "AAAUAAAAC0AA"),
        ]

        for (width, height, expected) in cases {
            let entry = OverrideBuilder.scaleEntry(pixelWidth: width, pixelHeight: height)
            XCTAssertEqual(entry, expected)
            XCTAssertTrue(
                OverrideBuilder.verifyEntry(entry, pixelWidth: width, pixelHeight: height)
            )
        }
    }

    func testManagedCatalogContainsFourLogicalAndRenderedModes() {
        XCTAssertEqual(
            OverrideBuilder.managedModes,
            [
                HiDPIModeSpec(
                    logicalWidth: 1440, logicalHeight: 810,
                    pixelWidth: 2880, pixelHeight: 1620
                ),
                HiDPIModeSpec(
                    logicalWidth: 1600, logicalHeight: 900,
                    pixelWidth: 3200, pixelHeight: 1800
                ),
                HiDPIModeSpec(
                    logicalWidth: 1920, logicalHeight: 1080,
                    pixelWidth: 3840, pixelHeight: 2160
                ),
                HiDPIModeSpec(
                    logicalWidth: 2560, logicalHeight: 1440,
                    pixelWidth: 5120, pixelHeight: 2880
                ),
            ]
        )
    }

    func testManagedPlistContainsTargetAndFourUniqueEntries() throws {
        let xml = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
        let data = try XCTUnwrap(xml.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let entries = try XCTUnwrap(plist["scale-resolutions"] as? [Data])

        XCTAssertEqual(plist["DisplayVendorID"] as? Int, 1507)
        XCTAssertEqual(plist["DisplayProductID"] as? Int, 9360)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries).count, 4)
    }

    func testOldTwoEntryPlistIsOutdatedAndMergePreservesExtras() throws {
        let oldEntries = [
            OverrideBuilder.scaleEntryData(pixelWidth: 2880, pixelHeight: 1620),
            OverrideBuilder.scaleEntryData(pixelWidth: 3200, pixelHeight: 1800),
        ]
        let custom = OverrideBuilder.scaleEntryData(pixelWidth: 4096, pixelHeight: 2304)
        let oldData = try plistData(
            entries: oldEntries + [custom, custom],
            extra: ["DisplayProductName": "Custom AOC", "CustomFlag": true]
        )
        XCTAssertEqual(OverrideBuilder.configurationState(for: oldData), .outdated)

        let mergedXML = try OverrideBuilder.buildManagedPlist(existingData: oldData).get()
        let mergedData = try XCTUnwrap(mergedXML.data(using: .utf8))
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: mergedData, format: nil)
                as? [String: Any]
        )
        let entries = try XCTUnwrap(root["scale-resolutions"] as? [Data])

        XCTAssertEqual(root["DisplayProductName"] as? String, "Custom AOC")
        XCTAssertEqual(root["CustomFlag"] as? Bool, true)
        XCTAssertEqual(entries.filter { $0 == custom }.count, 1)
        XCTAssertTrue(Set(OverrideBuilder.managedEntryData).isSubset(of: Set(entries)))
    }

    func testCurrentAllowsExtrasAndInvalidInputsAreRejected() throws {
        let extra = OverrideBuilder.scaleEntryData(pixelWidth: 4096, pixelHeight: 2304)
        let current = try plistData(entries: OverrideBuilder.managedEntryData + [extra])
        XCTAssertEqual(OverrideBuilder.configurationState(for: current), .current)

        let wrongID = try plistData(
            entries: OverrideBuilder.managedEntryData,
            vendorID: 1
        )
        guard case .invalid = OverrideBuilder.configurationState(for: wrongID) else {
            return XCTFail("wrong vendor must be invalid")
        }
        guard case .failure = OverrideBuilder.buildManagedPlist(existingData: wrongID) else {
            return XCTFail("invalid existing data must not be overwritten")
        }

        let wrongType = try PropertyListSerialization.data(
            fromPropertyList: [
                "DisplayVendorID": OverrideBuilder.vendorID,
                "DisplayProductID": OverrideBuilder.productID,
                "scale-resolutions": ["not data"],
            ],
            format: .xml,
            options: 0
        )
        guard case .invalid = OverrideBuilder.configurationState(for: wrongType) else {
            return XCTFail("non-data scale-resolutions must be invalid")
        }

        guard case .invalid = OverrideBuilder.configurationState(
            for: Data("not plist".utf8)
        ) else {
            return XCTFail("malformed plist must be invalid")
        }
    }

    func testActivationRequiresBothRequestedExactHiDPIModes() {
        let mode1080 = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        let mode1440 = ModeEntry(
            logicalWidth: 2560, logicalHeight: 1440,
            pixelWidth: 5120, pixelHeight: 2880,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )

        XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [mode1080]))
        XCTAssertFalse(OverrideBuilder.activationModesPresent(in: [mode1440]))
        XCTAssertTrue(
            OverrideBuilder.activationModesPresent(in: [mode1080, mode1440])
        )

        let wrong1080Render = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 1920, pixelHeight: 1080,
            refreshRate: 60, isHiDPI: false, isCurrent: false
        )
        let wrongFiveKLogical = ModeEntry(
            logicalWidth: 2880, logicalHeight: 1620,
            pixelWidth: 5120, pixelHeight: 2880,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        XCTAssertFalse(
            OverrideBuilder.activationModesPresent(in: [wrong1080Render, mode1440])
        )
        XCTAssertFalse(
            OverrideBuilder.activationModesPresent(in: [mode1080, wrongFiveKLogical])
        )
    }
}
