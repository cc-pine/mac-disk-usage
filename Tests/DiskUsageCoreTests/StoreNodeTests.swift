import XCTest
@testable import DiskUsageCore

/// 詰めた表現のノードが、欠損値と境界値を元の値どおりに保つことを確かめる。
final class StoreNodeTests: XCTestCase {
    private func node(
        logical: Int64? = nil,
        allocated: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil,
        identity: FileIdentity? = nil
    ) -> ScanStore.Node {
        ScanStore.Node(
            parent: -1, name: "n", kind: .file, isPackage: false,
            logicalSize: logical, allocatedSize: allocated, summary: SizeSummary(),
            modifiedDate: modified, createdDate: created,
            accessState: .readable, traversalState: .complete,
            fileIdentity: identity, exclusionReason: nil, listingDone: false
        )
    }

    func testZeroSizeIsDistinctFromUnknown() {
        XCTAssertEqual(node(logical: 0, allocated: 0).allocatedSize, 0)
        XCTAssertEqual(node(logical: 0, allocated: 0).logicalSize, 0)
        XCTAssertNil(node().allocatedSize)
        XCTAssertNil(node().logicalSize)
    }

    func testDatesRoundTripExactly() {
        let before2001 = Date(timeIntervalSince1970: 123_456_789.123_456)
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let recent = Date(timeIntervalSince1970: 1_759_000_000.987_654_321)
        XCTAssertEqual(node(modified: before2001).modifiedDate, before2001)
        XCTAssertEqual(node(modified: reference).modifiedDate, reference, "参照日ちょうどを欠損と取り違えない")
        XCTAssertEqual(node(created: recent).createdDate, recent)
        XCTAssertNil(node().modifiedDate)
        XCTAssertNil(node().createdDate)
    }

    func testZeroIdentityIsDistinctFromMissing() {
        XCTAssertEqual(node(identity: FileIdentity(device: 0, inode: 0)).fileIdentity, FileIdentity(device: 0, inode: 0))
        XCTAssertNil(node().fileIdentity)
    }

    func testSummaryRoundTripAndAdd() {
        var n = node()
        n.summary = SizeSummary(knownLogicalBytes: 5, knownAllocatedBytes: 4096, unknownLogicalItems: 2,
                                unknownAllocatedItems: 3, unreadableLocations: 1, hasUnvisitedDescendants: true)
        n.add(SizeSummary(knownLogicalBytes: 1, knownAllocatedBytes: 1, unknownAllocatedItems: 1))
        XCTAssertEqual(n.summary, SizeSummary(knownLogicalBytes: 6, knownAllocatedBytes: 4097, unknownLogicalItems: 2,
                                              unknownAllocatedItems: 4, unreadableLocations: 1, hasUnvisitedDescendants: true))
        XCTAssertEqual(n.knownAllocatedBytes, 4097)
    }

    func testNegativeSizeIsSanitizedConsistently() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let odd = b.add("odd", .file, parent: root, allocated: -10, logical: -5)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertEqual(store.item(odd)!.allocatedSize, 0)
        XCTAssertEqual(store.item(root)!.sizeSummary.knownAllocatedBytes, 0, "ノードと集計で同じ値にする")
    }

    func testErrorDescriptionsSurviveListingOutcomes() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let failed = b.add("failed", .directory, parent: root)
        let cut = b.add("cut", .directory, parent: root)
        b.listed(root)
        b.listed(failed, .failed(.denied, "Permission denied"))
        b.listed(cut, .interrupted("Input/output error"))
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertEqual(store.item(failed)!.errorDescription, "Permission denied")
        XCTAssertEqual(store.item(cut)!.errorDescription, "Input/output error")
        XCTAssertNil(store.item(root)!.errorDescription)
    }

    func testNodeStaysCompact() {
        XCTAssertLessThanOrEqual(ScanStore.nodeStride, 112, "100万件で約 110 MB に収める")
    }

    func testFinishWaitsForIndexBuiltByAnotherThread() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        for i in 0..<20_000 {
            b.add("f\(i)", .file, parent: root, allocated: Int64(i % 977))
        }
        b.listed(root)
        let store = ScanStore(rootPath: "/root", provisionalFileLimit: 10)
        store.apply(b.take())
        store.finalize()

        let started = expectation(description: "other builder")
        DispatchQueue.global().async {
            started.fulfill()
            _ = store.largestFiles(offset: 0, limit: 1)
        }
        wait(for: [started], timeout: 5)
        store.prepareFileIndex()
        let page = store.largestFiles(offset: 0, limit: 5)
        XCTAssertFalse(page.isProvisional, "prepareFileIndex は作成中の索引の完成を待ってから戻る")
        XCTAssertEqual(page.totalCount, 20_000)
    }
}
