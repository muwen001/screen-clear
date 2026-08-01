import Foundation
import XCTest
@testable import ScreenClear

final class OverrideBuilderTests: XCTestCase {
    func testKnownEntriesRoundTrip() {
        let cases = [
            (2880, 1620, "AAALQAAABlQA"),
            (3200, 1800, "AAAMgAAABwgA"),
        ]

        for (width, height, expected) in cases {
            let entry = OverrideBuilder.scaleEntry(pixelWidth: width, pixelHeight: height)
            XCTAssertEqual(entry, expected)
            XCTAssertTrue(
                OverrideBuilder.verifyEntry(entry, pixelWidth: width, pixelHeight: height)
            )
        }
    }

    func testGeneratedPlistContainsTargetAndThreeEntries() throws {
        let result = OverrideBuilder.buildPlist(
            renderResolutions: [(3840, 2160), (2880, 1620), (3200, 1800)]
        )
        let xml = try result.get()
        let data = try XCTUnwrap(xml.data(using: .utf8))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let entries = try XCTUnwrap(plist["scale-resolutions"] as? [Data])

        XCTAssertEqual(plist["DisplayVendorID"] as? Int, 1507)
        XCTAssertEqual(plist["DisplayProductID"] as? Int, 9360)
        XCTAssertEqual(entries.count, 3)
    }
}
