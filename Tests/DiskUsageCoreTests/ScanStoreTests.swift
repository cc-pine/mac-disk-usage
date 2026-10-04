import XCTest
@testable import DiskUsageCore

/// 発見順に ID を振りながらレコードを作る小さなビルダー。
struct RecordBuilder {
    private(set) var records: [ScanRecord] = []
    private var nextID: Int32 = 0

    @discardableResult
    mutating func add(
        _ name: String,
        _ kind: ItemKind,
        parent: ItemID?,
        allocated: Int64? = nil,
        logical: Int64? = nil,
        access: AccessState = .readable,
        exclusion: ExclusionReason? = nil
    ) -> ItemID {
        let id = ItemID(nextID)
        nextID += 1
        records.append(.item(DiscoveredItem(
            id: id,
            parentID: parent,
            name: name,
            kind: kind,
            logicalSize: logical ?? allocated,
            allocatedSize: allocated,
            accessState: access,
            exclusionReason: exclusion
        )))
        return id
    }

    mutating func listed(_ id: ItemID, _ outcome: ListingOutcome = .complete) {
        records.append(.directoryListed(id, outcome))
    }

    mutating func take() -> [ScanRecord] {
        defer { records.removeAll() }
        return records
    }
}

final class ScanStoreTests: XCTestCase {
    func testAggregatesKnownSizesWithoutDoubleCounting() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let a = b.add("a", .directory, parent: root)
        b.add("f1", .file, parent: a, allocated: 4096, logical: 100)
        b.add("f2", .file, parent: a, allocated: 8192, logical: 5000)
        b.listed(a)
        b.add("f3", .file, parent: root, allocated: 1000, logical: 1000)
        b.listed(root)

        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())

        let rootItem = store.item(root)!
        XCTAssertEqual(rootItem.sizeSummary.knownAllocatedBytes, 4096 + 8192 + 1000)
        XCTAssertEqual(rootItem.sizeSummary.knownLogicalBytes, 100 + 5000 + 1000)
        XCTAssertEqual(rootItem.traversalState, .complete)
        XCTAssertEqual(store.item(a)!.sizeSummary.knownAllocatedBytes, 12288)
        XCTAssertFalse(rootItem.isSizeIncomplete)
    }

    func testUnknownSizeIsCountedNotZeroed() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        b.add("known", .file, parent: root, allocated: 10)
        let unknown = b.add("unknown", .file, parent: root, allocated: nil)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())

        let summary = store.item(root)!.sizeSummary
        XCTAssertEqual(summary.knownAllocatedBytes, 10)
        XCTAssertEqual(summary.unknownAllocatedItems, 1)
        XCTAssertTrue(summary.isIncomplete)
        XCTAssertNil(store.item(unknown)!.allocatedSize)
        XCTAssertNil(store.item(unknown)!.displayAllocatedBytes)
    }

    func testUnreadableDirectoryPropagatesWithoutGuessingCounts() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let locked = b.add("locked", .directory, parent: root)
        b.add("ok", .file, parent: root, allocated: 5)
        b.listed(root)
        b.listed(locked, .failed(.denied, "Permission denied"))
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())

        let lockedItem = store.item(locked)!
        XCTAssertEqual(lockedItem.accessState, .denied)
        XCTAssertEqual(lockedItem.traversalState, .partial)
        XCTAssertEqual(lockedItem.sizeSummary.unreadableLocations, 1)
        let rootItem = store.item(root)!
        XCTAssertEqual(rootItem.traversalState, .partial)
        XCTAssertEqual(rootItem.sizeSummary.unreadableLocations, 1)
        XCTAssertEqual(rootItem.sizeSummary.unknownAllocatedItems, 0)
        XCTAssertEqual(store.currentCounts.problemItems, 1)
        XCTAssertEqual(store.currentCounts.files, 1)
    }

    func testEmptyFolderIsCompleteZero() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let empty = b.add("empty", .directory, parent: root)
        b.listed(root)
        b.listed(empty)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertEqual(store.item(empty)!.traversalState, .complete)
        XCTAssertEqual(store.item(empty)!.displayAllocatedBytes, 0)
        XCTAssertEqual(store.item(root)!.traversalState, .complete)
    }

    func testDirectoryStaysPendingUntilChildrenComplete() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let child = b.add("child", .directory, parent: root)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertEqual(store.item(root)!.traversalState, .pending)
        XCTAssertTrue(store.item(root)!.isSizeIncomplete)

        b.listed(child)
        store.apply(b.take())
        XCTAssertEqual(store.item(root)!.traversalState, .complete)
    }

    func testFinalizeMarksUnvisitedAsPartial() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let visited = b.add("visited", .directory, parent: root)
        let unvisited = b.add("unvisited", .directory, parent: root)
        b.add("f", .file, parent: visited, allocated: 7)
        b.listed(visited)
        b.listed(root, .interrupted(nil))
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertTrue(store.finalize())

        XCTAssertEqual(store.item(visited)!.traversalState, .complete)
        let unvisitedItem = store.item(unvisited)!
        XCTAssertEqual(unvisitedItem.traversalState, .partial)
        XCTAssertEqual(unvisitedItem.accessState, .notScanned)
        XCTAssertTrue(unvisitedItem.sizeSummary.hasUnvisitedDescendants)
        let rootItem = store.item(root)!
        XCTAssertEqual(rootItem.traversalState, .partial)
        XCTAssertTrue(rootItem.sizeSummary.hasUnvisitedDescendants)
        XCTAssertEqual(rootItem.sizeSummary.knownAllocatedBytes, 7)
    }

    func testExcludedDirectoryIsNotPendingAndCountedSeparately() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let other = b.add("Volumes", .directory, parent: root, exclusion: .scopeRule)
        b.listed(root)
        let store = ScanStore(rootPath: "/")
        store.apply(b.take())
        XCTAssertEqual(store.item(other)!.traversalState, .excluded)
        XCTAssertEqual(store.item(root)!.traversalState, .complete)
        XCTAssertEqual(store.currentCounts.excludedItems, 1)
        XCTAssertEqual(store.currentCounts.problemItems, 0)
    }

    func testSymlinksAreNotCounted() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        b.add("link", .symbolicLink, parent: root, allocated: 4096)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        XCTAssertEqual(store.item(root)!.sizeSummary.knownAllocatedBytes, 0)
        XCTAssertEqual(store.currentCounts.symbolicLinks, 1)
    }

    func testChildrenOrderingKnownDescendingUnknownLastNameTiebreak() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        b.add("b", .file, parent: root, allocated: 10)
        b.add("a", .file, parent: root, allocated: 10)
        b.add("big", .file, parent: root, allocated: 100)
        b.add("unknown", .file, parent: root, allocated: nil)
        b.add("link", .symbolicLink, parent: root)
        b.add("zero", .file, parent: root, allocated: 0)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())

        let names = store.children(of: root).items.map(\.name)
        XCTAssertEqual(names, ["big", "a", "b", "zero", "link", "unknown"])
        let page = store.children(of: root, offset: 1, limit: 2)
        XCTAssertEqual(page.items.map(\.name), ["a", "b"])
        XCTAssertEqual(page.totalCount, 6)
    }

    func testPathAndAncestryAreBuiltFromParents() {
        var b = RecordBuilder()
        let root = b.add("ignored-root-name", .directory, parent: nil)
        let users = b.add("Users", .directory, parent: root)
        let file = b.add("a.txt", .file, parent: users, allocated: 1)
        let store = ScanStore(rootPath: "/")
        store.apply(b.take())
        XCTAssertEqual(store.path(of: root), "/")
        XCTAssertEqual(store.path(of: file), "/Users/a.txt")
        XCTAssertEqual(store.ancestry(of: file), [root, users, file])
    }

    func testLargestFilesProvisionalThenFull() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        for i in 0..<50 {
            b.add("f\(i)", .file, parent: root, allocated: Int64(i * 10))
        }
        b.add("unknown", .file, parent: root, allocated: nil)
        b.listed(root)
        let store = ScanStore(rootPath: "/root", provisionalFileLimit: 5)
        store.apply(b.take())

        let provisional = store.largestFiles(offset: 0, limit: 100)
        XCTAssertTrue(provisional.isProvisional)
        XCTAssertEqual(provisional.items.map(\.name), ["f49", "f48", "f47", "f46", "f45"])

        store.finalize()
        let full = store.largestFiles(offset: 0, limit: 100)
        XCTAssertFalse(full.isProvisional)
        XCTAssertEqual(full.totalCount, 51)
        XCTAssertEqual(full.items.first?.name, "f49")
        XCTAssertEqual(full.items.last?.name, "unknown")
        let page = store.largestFiles(offset: 10, limit: 2)
        XCTAssertEqual(page.items.map(\.name), ["f39", "f38"])
    }

    func testEqualSizeAndNameAreOrderedByParentPath() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let z = b.add("z", .directory, parent: root)
        let a = b.add("a", .directory, parent: root)
        let inZ = b.add("package.json", .file, parent: z, allocated: 4096)
        let inA = b.add("package.json", .file, parent: a, allocated: 4096)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        store.finalize()
        XCTAssertEqual(store.largestFiles().items.map(\.id), [inA, inZ])
    }

    func testLateBatchAfterFinalizeIsIgnored() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        store.finalize()
        let revision = store.currentRevision
        b.add("late", .file, parent: root, allocated: 1)
        store.apply(b.take())
        XCTAssertEqual(store.itemCount, 1)
        XCTAssertEqual(store.currentRevision, revision)
    }

    func testConcurrentReadsDuringApply() {
        let store = ScanStore(rootPath: "/root")
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        store.apply(b.take())
        let done = expectation(description: "writer")
        DispatchQueue.global().async {
            var writer = RecordBuilder()
            _ = writer.add("root", .directory, parent: nil)
            _ = writer.take()
            for i in 0..<2_000 {
                writer.add("f\(i)", .file, parent: root, allocated: Int64(i))
                store.apply(writer.take())
            }
            done.fulfill()
        }
        for _ in 0..<200 {
            let page = store.children(of: root, offset: 0, limit: 10)
            XCTAssertLessThanOrEqual(page.items.count, 10)
            _ = store.largestFiles(offset: 0, limit: 5)
            _ = store.item(root)
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(store.item(root)!.sizeSummary.knownAllocatedBytes, Int64((0..<2_000).reduce(0, +)))
    }

    func testRevisionAdvancesPerBatch() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let store = ScanStore(rootPath: "/root")
        XCTAssertEqual(store.currentRevision, 0)
        store.apply(b.take())
        XCTAssertEqual(store.currentRevision, 1)
        store.apply([])
        XCTAssertEqual(store.currentRevision, 1)
        b.listed(root)
        store.apply(b.take())
        XCTAssertEqual(store.currentRevision, 2)
    }
}
