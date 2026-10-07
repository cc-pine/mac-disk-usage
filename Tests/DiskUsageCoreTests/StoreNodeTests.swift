import XCTest
@testable import DiskUsageCore

/// 詰めた表現のノード・名前の領域・塊の配列が、欠損値と境界値を元の値どおりに保つことを確かめる。
final class StoreNodeTests: XCTestCase {
    private func node(
        logical: Int64? = nil,
        allocated: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil
    ) -> ScanStore.Node {
        ScanStore.Node(
            parent: -1, name: NameStorage.Location(chunk: 0, offset: 0, length: 0), kind: .file, isPackage: false,
            logicalSize: logical, allocatedSize: allocated,
            modifiedDate: modified, createdDate: created,
            accessState: .readable, traversalState: .complete, exclusionReason: nil
        )
    }

    func testZeroSizeIsDistinctFromUnknown() {
        XCTAssertEqual(node(logical: 0, allocated: 0).allocatedSize, 0)
        XCTAssertEqual(node(logical: 0, allocated: 0).logicalSize, 0)
        XCTAssertNil(node().allocatedSize)
        XCTAssertNil(node().logicalSize)
        XCTAssertLessThan(node().allocatedSortKey, node(allocated: 0).allocatedSortKey, "不明は 0 より後ろに並ぶ")
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

    func testStatesAndFlagsAreIndependent() {
        let kinds: [ItemKind] = [.file, .directory, .symbolicLink, .other]
        let accesses: [AccessState] = [.readable, .denied, .error, .notScanned]
        let traversals: [TraversalState] = [.pending, .partial, .complete, .excluded]
        let exclusions: [ExclusionReason?] = [nil, .otherVolume, .duplicatePath, .scopeRule]
        var n = node()
        for kind in kinds {
            for access in accesses {
                for traversal in traversals {
                    for exclusion in exclusions {
                        n.kind = kind
                        n.accessState = access
                        n.traversalState = traversal
                        n.exclusionReason = exclusion
                        XCTAssertEqual(n.kind, kind)
                        XCTAssertEqual(n.accessState, access)
                        XCTAssertEqual(n.traversalState, traversal)
                        XCTAssertEqual(n.exclusionReason, exclusion)
                    }
                }
            }
        }
        n.isPackage = true
        n.subtreeIncomplete = true
        XCTAssertTrue(n.isPackage)
        XCTAssertFalse(n.listingDone)
        XCTAssertTrue(n.subtreeIncomplete)
        XCTAssertFalse(n.hasUnvisitedDescendants)
        n.isPackage = false
        n.hasUnvisitedDescendants = true
        XCTAssertFalse(n.isPackage)
        XCTAssertTrue(n.subtreeIncomplete)
        XCTAssertTrue(n.hasUnvisitedDescendants)
        XCTAssertEqual(n.exclusionReason, .scopeRule, "フラグの変更で状態を壊さない")
    }

    func testZeroIdentityIsDistinctFromMissing() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        b.listed(root)
        var records = b.take()
        records.append(.item(DiscoveredItem(id: ItemID(1), parentID: root, name: "zero", kind: .file,
                                            fileIdentity: FileIdentity(device: 0, inode: 0))))
        records.append(.item(DiscoveredItem(id: ItemID(2), parentID: root, name: "none", kind: .file)))
        let store = ScanStore(rootPath: "/root")
        store.apply(records)
        XCTAssertEqual(store.item(ItemID(1))!.fileIdentity, FileIdentity(device: 0, inode: 0))
        XCTAssertNil(store.item(ItemID(2))!.fileIdentity)
    }

    func testIdentityIsDroppedOnlyAfterDeviceTableIsFull() {
        var records: [ScanRecord] = [.item(DiscoveredItem(id: ItemID(0), parentID: nil, name: "root", kind: .directory))]
        let total = Int(UInt16.max) + 10
        for i in 1...total {
            records.append(.item(DiscoveredItem(id: ItemID(Int32(i)), parentID: ItemID(0), name: "f\(i)", kind: .file,
                                                fileIdentity: FileIdentity(device: UInt64(i), inode: UInt64(i) * 3))))
        }
        let store = ScanStore(rootPath: "/root")
        store.apply(records)
        XCTAssertEqual(store.item(ItemID(1))!.fileIdentity, FileIdentity(device: 1, inode: 3))
        XCTAssertEqual(store.item(ItemID(65_535))!.fileIdentity, FileIdentity(device: 65_535, inode: 196_605))
        XCTAssertNil(store.item(ItemID(Int32(total)))!.fileIdentity, "表が満杯なら識別情報なしとして扱い、移動を断る")
    }

    func testDirectorySummaryRoundTripAndSaturates() {
        var info = ScanStore.DirectoryInfo(SizeSummary(knownLogicalBytes: 5, knownAllocatedBytes: 4096, unknownLogicalItems: 2,
                                                       unknownAllocatedItems: 3, unreadableLocations: 1))
        info.add(SizeSummary(knownLogicalBytes: 1, knownAllocatedBytes: 1, unknownAllocatedItems: 1))
        XCTAssertEqual(info.summary(hasUnvisitedDescendants: true),
                       SizeSummary(knownLogicalBytes: 6, knownAllocatedBytes: 4097, unknownLogicalItems: 2,
                                   unknownAllocatedItems: 4, unreadableLocations: 1, hasUnvisitedDescendants: true))
        info.add(SizeSummary(knownAllocatedBytes: .max, unknownLogicalItems: Int(Int32.max)))
        XCTAssertEqual(info.knownAllocatedBytes, .max, "負に回り込まない")
        XCTAssertEqual(info.unknownLogicalItems, .max)
    }

    func testNamesRoundTripAcrossChunks() {
        let storage = NameStorage()
        let samples = ["", "a", "日本語のフォルダ", "🧪 test", String(repeating: "x", count: 255)]
        var stored: [(String, NameStorage.Location)] = []
        // 塊（64 KiB）の境目をまたぐまで書き込む
        for i in 0..<2_000 {
            let name = samples[i % samples.count] + "\(i)"
            stored.append((name, storage.append(name)))
        }
        XCTAssertGreaterThan(stored.last!.1.chunk, 0)
        for (name, location) in stored {
            XCTAssertEqual(storage.string(location), name)
        }
        let empty = storage.append("")
        XCTAssertEqual(storage.string(empty), "")

        let long = storage.append(String(repeating: "y", count: 70_000))
        XCTAssertEqual(Int(long.length), Int(UInt16.max), "実際には現れない長さの名前は切り詰める")
    }

    func testNameOrderIsByteOrder() {
        let storage = NameStorage()
        func compare(_ lhs: String, _ rhs: String) -> Int {
            NameStorage.compare(storage.bytes(storage.append(lhs)), storage.bytes(storage.append(rhs)))
        }
        XCTAssertEqual(compare("a", "b"), -1)
        XCTAssertEqual(compare("b", "a"), 1)
        XCTAssertEqual(compare("a", "ab"), -1, "前方一致なら短い方が先")
        XCTAssertEqual(compare("", "a"), -1)
        XCTAssertEqual(compare("同じ", "同じ"), 0)
        XCTAssertEqual(compare("Z", "a"), -1, "大文字小文字はコードポイント順")
    }

    func testChunkedBufferKeepsValuesAcrossChunks() {
        let buffer = ChunkedBuffer<Int32>()
        for i in 0..<200_000 {
            buffer.append(Int32(i))
        }
        XCTAssertEqual(buffer.count, 200_000)
        buffer[65_536] += 1
        XCTAssertEqual(buffer[0], 0)
        XCTAssertEqual(buffer[65_535], 65_535)
        XCTAssertEqual(buffer[65_536], 65_537)
        XCTAssertEqual(buffer[199_999], 199_999)
        XCTAssertTrue(buffer.contains(index: 199_999))
        XCTAssertFalse(buffer.contains(index: 200_000))
        XCTAssertFalse(buffer.contains(index: -1))
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
        XCTAssertLessThanOrEqual(ScanStore.nodeStride, 64, "1000 万件で約 640 MB に収める")
        XCTAssertLessThanOrEqual(ScanStore.directoryStride, 40)
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

    /// 暫定の並び（親のパスを都度たどる）と、確定後の全件索引（フォルダの訪問順を使う）が一致する。
    func testProvisionalAndFullOrdersAgreeOnPathTies() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        // 「a」と「a-b」のように、文字列の比較と成分ごとの比較で順が変わりうる名前を混ぜる
        let names = ["a", "a-b", "b", "a.b", "A"]
        var directories = [root]
        for name in names {
            let directory = b.add(name, .directory, parent: root)
            directories.append(directory)
            for inner in names {
                directories.append(b.add(inner, .directory, parent: directory))
            }
        }
        for directory in directories {
            b.add("same.txt", .file, parent: directory, allocated: 4096)
            b.add("other.txt", .file, parent: directory, allocated: 4096)
        }
        for directory in directories {
            b.listed(directory)
        }
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())
        let provisional = store.largestFiles(offset: 0, limit: 1_000)
        XCTAssertTrue(provisional.isProvisional)
        store.finalize()
        let full = store.largestFiles(offset: 0, limit: 1_000)
        XCTAssertFalse(full.isProvisional)
        XCTAssertEqual(provisional.items.map(\.id), full.items.map(\.id))
        let paths = full.items.filter { $0.name == "same.txt" }.map { store.path(of: $0.id)! }
        XCTAssertEqual(paths.first, "/root/same.txt", "祖先のフォルダは子孫より先")
        XCTAssertEqual(paths.prefix(3), ["/root/same.txt", "/root/A/same.txt", "/root/A/A/same.txt"])
    }
}
