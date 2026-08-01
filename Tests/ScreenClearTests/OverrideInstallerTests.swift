import Foundation
import XCTest
@testable import ScreenClear

final class OverrideInstallerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "screenclear-installer-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempRoot)
    }

    func testPathStateDistinguishesMissingOutdatedCurrentAndInvalid() throws {
        let target = tempRoot.appendingPathComponent("DisplayProductID-2490")
        XCTAssertEqual(
            OverrideInstaller.configurationState(atPath: target.path),
            .missing
        )

        let oldData = try PropertyListSerialization.data(
            fromPropertyList: [
                "DisplayVendorID": OverrideBuilder.vendorID,
                "DisplayProductID": OverrideBuilder.productID,
                "scale-resolutions": [
                    OverrideBuilder.scaleEntryData(pixelWidth: 2880, pixelHeight: 1620),
                    OverrideBuilder.scaleEntryData(pixelWidth: 3200, pixelHeight: 1800),
                ],
            ],
            format: .xml,
            options: 0
        )
        try oldData.write(to: target)
        XCTAssertEqual(
            OverrideInstaller.configurationState(atPath: target.path),
            .outdated
        )

        let currentXML = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
        try currentXML.write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            OverrideInstaller.configurationState(atPath: target.path),
            .current
        )

        try Data("broken".utf8).write(to: target)
        guard case .invalid = OverrideInstaller.configurationState(atPath: target.path) else {
            return XCTFail("broken plist must be invalid")
        }
    }

    func testExistingDataReturnsNilBytesAndReadFailure() throws {
        let target = tempRoot.appendingPathComponent("override")
        guard case .success(nil) = OverrideInstaller.existingData(atPath: target.path) else {
            return XCTFail("missing target must return nil data")
        }

        let expected = Data("plist bytes".utf8)
        try expected.write(to: target)
        guard case .success(let loaded?) = OverrideInstaller.existingData(
            atPath: target.path
        ) else {
            return XCTFail("file target must return its data")
        }
        XCTAssertEqual(loaded, expected)

        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        guard case .failure = OverrideInstaller.existingData(atPath: target.path) else {
            return XCTFail("unreadable target must return a failure")
        }
    }

    func testPrivilegedCommandAtomicallyReplacesValidTargetAndQuotesPaths() throws {
        let directory = tempRoot.appendingPathComponent("target dir's", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = directory.appendingPathComponent("DisplayProductID-2490")
        let source = tempRoot.appendingPathComponent("new config.plist")
        try Data("old".utf8).write(to: target)
        let newXML = try OverrideBuilder.buildManagedPlist(existingData: nil).get()
        try newXML.write(to: source, atomically: true, encoding: .utf8)

        let command = OverrideInstaller.privilegedInstallCommand(
            sourcePath: source.path,
            targetDirectory: directory.path,
            targetFile: target.path,
            token: "TEST"
        )
        XCTAssertEqual(try runShell(command), 0)
        XCTAssertEqual(try Data(contentsOf: target), Data(newXML.utf8))
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }

    func testPrivilegedCommandKeepsOldTargetWhenValidationFails() throws {
        let directory = tempRoot.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let target = directory.appendingPathComponent("DisplayProductID-2490")
        let source = tempRoot.appendingPathComponent("invalid.plist")
        let old = Data("old-target".utf8)
        try old.write(to: target)
        try Data("<?xml version=\"1.0\"?><plist><dict>".utf8).write(to: source)

        let command = OverrideInstaller.privilegedInstallCommand(
            sourcePath: source.path,
            targetDirectory: directory.path,
            targetFile: target.path,
            token: "FAIL"
        )
        XCTAssertNotEqual(try runShell(command), 0)
        XCTAssertEqual(try Data(contentsOf: target), old)
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }

    func testAppleScriptLiteralRoundTripsQuotesAndBackslashes() throws {
        let value = #"printf "quoted\path""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "return \(OverrideInstaller.appleScriptStringLiteral(value))",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let rendered = try XCTUnwrap(String(data: data, encoding: .utf8))
            .trimmingCharacters(in: .newlines)
        XCTAssertEqual(rendered, value)
    }

    private func runShell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func stagedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".screenclear-") }
    }
}
