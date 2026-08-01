import AppKit
import XCTest
@testable import ScreenClear

@MainActor
final class MenuBarIconTests: XCTestCase {
    private func temporaryURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenclear-menu-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent(name)
    }

    func testValidPDFLoadsAsTemplateImage() throws {
        let url = try temporaryURL("MenuBarIcon.pdf")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        try view.dataWithPDF(inside: view.bounds).write(to: url, options: .atomic)

        let image = try XCTUnwrap(MenuBarIcon.image(from: url))

        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testMissingAndInvalidResourcesReturnNil() throws {
        XCTAssertNil(MenuBarIcon.image(from: nil))
        let invalid = try temporaryURL("MenuBarIcon.pdf")
        try Data("not an image".utf8).write(to: invalid, options: .atomic)
        XCTAssertNil(MenuBarIcon.image(from: invalid))
    }

    func testFallbackRemainsDisplaySymbol() {
        XCTAssertEqual(MenuBarIcon.fallbackSystemName, "display")
    }
}
