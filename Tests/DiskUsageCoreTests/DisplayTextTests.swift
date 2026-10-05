import XCTest
@testable import DiskUsageCore

final class DisplayTextTests: XCTestCase {
    private func item(
        kind: ItemKind,
        allocated: Int64? = nil,
        summary: SizeSummary = SizeSummary(),
        access: AccessState = .readable,
        traversal: TraversalState = .complete,
        exclusion: ExclusionReason? = nil
    ) -> ScanItem {
        ScanItem(
            id: ItemID(1), parentID: ItemID(0), name: "x", kind: kind, isPackage: false,
            logicalSize: allocated, allocatedSize: allocated, sizeSummary: summary,
            modifiedDate: nil, createdDate: nil, accessState: access, traversalState: traversal,
            fileIdentity: nil, exclusionReason: exclusion, errorDescription: nil
        )
    }

    func testUnknownAndUncountedAreNeverShownAsZero() {
        XCTAssertEqual(DisplayText.size(of: item(kind: .file, allocated: nil)), "不明")
        XCTAssertEqual(DisplayText.size(of: item(kind: .file, allocated: 0)), "0 bytes")
        XCTAssertEqual(DisplayText.size(of: item(kind: .symbolicLink)), "—")
        XCTAssertEqual(DisplayText.size(of: item(kind: .directory, access: .denied, traversal: .partial)), "不明")
        XCTAssertEqual(DisplayText.size(of: item(kind: .directory, traversal: .excluded, exclusion: .otherVolume)), "対象外")
    }

    func testPartialDirectoryIsMarked() {
        let partial = item(kind: .directory, summary: SizeSummary(knownAllocatedBytes: 2_000_000, unreadableLocations: 1), traversal: .partial)
        XCTAssertEqual(DisplayText.size(of: partial), "2.0 MB・一部未取得")
        let scanning = item(kind: .directory, summary: SizeSummary(knownAllocatedBytes: 1000), traversal: .pending)
        XCTAssertEqual(DisplayText.size(of: scanning), "1.0 KB・一部未取得")
        let complete = item(kind: .directory, summary: SizeSummary(knownAllocatedBytes: 1000))
        XCTAssertEqual(DisplayText.size(of: complete), "1.0 KB")
    }

    func testExcludedIsNotDescribedAsReadable() {
        let excluded = item(kind: .directory, traversal: .excluded, exclusion: .duplicatePath)
        XCTAssertEqual(DisplayText.access(of: excluded), "未読込・同じフォルダへの別経路のため対象外")
        XCTAssertEqual(DisplayText.access(of: item(kind: .directory, access: .denied, traversal: .partial)), "アクセス拒否・一部のみ走査")
    }

    func testStateTextDistinguishesPartialResults() {
        XCTAssertEqual(DisplayText.state(.scanning, isStale: false), "スキャン中（部分結果）")
        XCTAssertEqual(DisplayText.state(.cancelled, isStale: false), "中止（部分結果）")
        XCTAssertEqual(DisplayText.state(.completedWithErrors, isStale: false), "完了（一部未取得）")
        XCTAssertEqual(DisplayText.state(.completed, isStale: true), "完了・結果が古くなっています")
    }

    func testElapsed() {
        XCTAssertEqual(DisplayText.elapsed(59.9), "59秒")
        XCTAssertEqual(DisplayText.elapsed(125), "2分5秒")
    }
}
