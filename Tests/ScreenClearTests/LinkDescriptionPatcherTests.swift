import Foundation
import XCTest
@testable import ScreenClear

final class LinkDescriptionPatcherTests: XCTestCase {
    func testApplyUsesProvidedBackupDirectoryAndPatchesUUID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenclear-tests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("display-\(UUID().uuidString).plist")
        let backups = root.appendingPathComponent("Backups", isDirectory: true)
        let unexpected = LinkDescriptionPatcher.backupDir
            .appendingPathComponent(source.lastPathComponent + ".bak")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unexpected)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture: [String: Any] = [
            "DisplaySets": [
                "Configs": [[
                    "DisplayConfig": [[
                        "UUID": "TEST-UUID",
                        "CurrentInfo": ["Wide": 1920, "High": 1080, "Scale": 2],
                    ]],
                ]],
            ],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture, format: .xml, options: 0
        )
        try data.write(to: source)

        let patched = try LinkDescriptionPatcher.apply(
            filePath: source.path,
            uuid: "TEST-UUID",
            fallbackLogical: nil,
            backupDirectory: backups
        )

        XCTAssertTrue(patched)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backups.appendingPathComponent(source.lastPathComponent + ".bak").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))

        let patchedData = try Data(contentsOf: source)
        let patchedRoot = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: patchedData, format: nil)
                as? [String: Any]
        )
        let sets = try XCTUnwrap(patchedRoot["DisplaySets"] as? [String: Any])
        let configs = try XCTUnwrap(sets["Configs"] as? [[String: Any]])
        let displayConfig = try XCTUnwrap(configs.first?["DisplayConfig"] as? [[String: Any]])
        let link = try XCTUnwrap(displayConfig.first?["LinkDescription"] as? [String: Any])
        XCTAssertEqual(link["Range"] as? Int, 1)
        XCTAssertEqual(link["PixelEncoding"] as? Int, 0)
    }
}
