import XCTest
@testable import ScreenClear

final class ModeEntryTests: XCTestCase {
    func testIDIncludesLogicalDimensions() {
        let standard = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        let alternate = ModeEntry(
            logicalWidth: 1600, logicalHeight: 900,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )

        XCTAssertNotEqual(standard.id, alternate.id)
    }

    func testComparisonRejectsSamePixelsWithDifferentLogicalMode() {
        let hiDPI = ModeEntry(
            logicalWidth: 1280, logicalHeight: 720,
            pixelWidth: 2560, pixelHeight: 1440,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        let oneX = ModeEntry(
            logicalWidth: 2560, logicalHeight: 1440,
            pixelWidth: 2560, pixelHeight: 1440,
            refreshRate: 60, isHiDPI: false, isCurrent: false
        )

        XCTAssertFalse(hiDPI.matchesConfiguration(of: oneX))
    }

    func testComparisonUsesRefreshTolerance() {
        let target = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60, isHiDPI: true, isCurrent: false
        )
        let within = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60.08, isHiDPI: true, isCurrent: true
        )
        let outside = ModeEntry(
            logicalWidth: 1920, logicalHeight: 1080,
            pixelWidth: 3840, pixelHeight: 2160,
            refreshRate: 60.2, isHiDPI: true, isCurrent: true
        )

        XCTAssertTrue(target.matchesConfiguration(of: within))
        XCTAssertFalse(target.matchesConfiguration(of: outside))
    }
}
