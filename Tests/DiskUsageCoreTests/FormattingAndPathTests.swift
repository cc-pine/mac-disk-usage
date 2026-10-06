import XCTest
@testable import DiskUsageCore

final class FormattingAndPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 日本語の文言を確かめる。英語は L10nTests で確かめる
        L10n.language = .japanese
    }

    func testDecimalUnits() {
        XCTAssertEqual(ByteFormatting.string(0), "0 バイト")
        XCTAssertEqual(ByteFormatting.string(999), "999 バイト")
        XCTAssertEqual(ByteFormatting.string(1000), "1.0 KB")
        XCTAssertEqual(ByteFormatting.string(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteFormatting.string(1_000_000_000), "1.0 GB")
        XCTAssertEqual(ByteFormatting.string(123_456_789_012), "123.5 GB")
    }

    func testRoundingCarriesToNextUnit() {
        XCTAssertEqual(ByteFormatting.string(999_960), "1.0 MB")
        XCTAssertEqual(ByteFormatting.string(999_940), "999.9 KB")
    }

    func testUnknownIsNotZero() {
        XCTAssertEqual(ByteFormatting.string(nil), "不明")
        XCTAssertEqual(ByteFormatting.string(Int64?.some(0)), "0 バイト")
    }

    func testSummaryMarksIncomplete() {
        var summary = SizeSummary(knownAllocatedBytes: 10_000_000_000)
        XCTAssertEqual(ByteFormatting.summaryString(summary), "10.0 GB")
        summary.unreadableLocations = 1
        XCTAssertEqual(ByteFormatting.summaryString(summary), "10.0 GB・一部未取得")
    }

    func testPathNormalization() {
        XCTAssertEqual(PathUtilities.normalize("/"), "/")
        XCTAssertEqual(PathUtilities.normalize("//Users///me/"), "/Users/me")
        XCTAssertEqual(PathUtilities.join("/", "Users"), "/Users")
        XCTAssertEqual(PathUtilities.join("/Users", "me"), "/Users/me")
        XCTAssertEqual(PathUtilities.parent(of: "/Users/me"), "/Users")
        XCTAssertEqual(PathUtilities.parent(of: "/Users"), "/")
        XCTAssertNil(PathUtilities.parent(of: "/"))
    }

    func testContainmentUsesComponentsNotPrefix() {
        XCTAssertTrue(PathUtilities.isSameOrDescendant("/Users/me/a", of: "/Users/me"))
        XCTAssertTrue(PathUtilities.isSameOrDescendant("/Users/me", of: "/Users/me"))
        XCTAssertFalse(PathUtilities.isSameOrDescendant("/Users/meme", of: "/Users/me"))
        XCTAssertTrue(PathUtilities.isSameOrDescendant("/anything", of: "/"))
        XCTAssertTrue(PathUtilities.hasDotSegments("/a/../b"))
        XCTAssertFalse(PathUtilities.hasDotSegments("/a/..b"))
    }

    func testStateTransitions() {
        XCTAssertTrue(ScanState.scanning.canTransition(to: .cancelling))
        XCTAssertTrue(ScanState.cancelling.canTransition(to: .cancelled))
        XCTAssertFalse(ScanState.cancelling.canTransition(to: .completed))
        XCTAssertFalse(ScanState.completed.canTransition(to: .cancelled))
        XCTAssertTrue(ScanState.cancelled.isPartial)
        XCTAssertFalse(ScanState.completed.isPartial)
    }
}
