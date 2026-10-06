import Foundation
import XCTest
@testable import DiskUsageCore

/// 受け入れ確認の観点（集計・範囲・進捗・ファイル操作・鮮度）をまたぐ場面のテスト。
final class ScenarioTests: XCTestCase {
    // MARK: - ファイル操作

    func testConcurrentAndRepeatedMovesAreGated() async throws {
        let fs = MockFileSystem()
        fs.dir("/Users").dir("/Users/me").dir("/Users/me/.Trash").dir("/Users/me/work")
        fs.file("/Users/me/work/big.mov", allocated: 5_000).file("/Users/me/work/a.bin", allocated: 10)
        let trasher = RecordingTrasher(fileSystem: fs)
        let gate = Gate()
        trasher.gate = gate
        let coordinator = ScanCoordinator(provider: fs)
        let session = try coordinator.start(scope: ScanScope(rootPath: "/Users/me/work", kind: .folder)!)
        _ = await session.waitUntilFinished()
        let service = ItemActionService(coordinator: coordinator, provider: fs, trasher: trasher, policy: TrashPolicy(homeDirectory: "/Users/me"))
        let items = session.store.children(of: session.store.rootID!).items
        let big = try service.candidate(for: items.first { $0.name == "big.mov" }!.id, in: session).get()
        let small = try service.candidate(for: items.first { $0.name == "a.bin" }!.id, in: session).get()

        let first = expectation(description: "first move")
        DispatchQueue.global().async {
            XCTAssertNotNil(try? service.moveToTrash(big, in: session).get())
            first.fulfill()
        }
        blockingWait(trasher.entered)
        // 1件目の移動中は、別の移動もスキャンも始めない
        XCTAssertEqual(service.moveToTrash(small, in: session), .failure(.blocked(.operationInProgress)))
        XCTAssertThrowsError(try coordinator.start(scope: ScanScope(rootPath: "/Users/me/work", kind: .folder)!)) { error in
            XCTAssertEqual(error as? ScanCoordinatorError, .fileOperationInProgress)
        }
        gate.open()
        await fulfillment(of: [first], timeout: 5)

        XCTAssertEqual(service.moveToTrash(big, in: session), .failure(.blocked(.alreadyMoved)))
        XCTAssertEqual(trasher.paths, ["/Users/me/work/big.mov"])
    }

    func testMismatchedCandidateNeverReachesTrasher() async throws {
        let fs = MockFileSystem()
        fs.dir("/Users").dir("/Users/me").dir("/Users/me/.Trash").dir("/Users/me/work")
        fs.file("/Users/me/work/big.mov", allocated: 5_000).file("/Users/me/work/a.bin", allocated: 10)
        let trasher = RecordingTrasher(fileSystem: fs)
        let coordinator = ScanCoordinator(provider: fs)
        let session = try coordinator.start(scope: ScanScope(rootPath: "/Users/me/work", kind: .folder)!)
        _ = await session.waitUntilFinished()
        let service = ItemActionService(coordinator: coordinator, provider: fs, trasher: trasher, policy: TrashPolicy(homeDirectory: "/Users/me"))
        let items = session.store.children(of: session.store.rootID!).items
        let big = try service.candidate(for: items.first { $0.name == "big.mov" }!.id, in: session).get()
        let small = try service.candidate(for: items.first { $0.name == "a.bin" }!.id, in: session).get()

        // 項目 ID は big.mov のまま、場所と識別情報だけ別の項目にすり替えた確認内容
        let forged = TrashCandidate(
            scanID: big.scanID, itemID: big.itemID, name: small.name, path: small.path,
            allocatedSize: small.allocatedSize, identity: small.identity
        )
        guard case .failure(.changedSinceScan) = service.moveToTrash(forged, in: session) else {
            return XCTFail("確認内容と結果が一致しなければ移動しない")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
        XCTAssertFalse(session.result.isStale)
    }

    func testRescanAfterTrashReplacesResult() async throws {
        let fs = MockFileSystem()
        fs.dir("/Users").dir("/Users/me").dir("/Users/me/.Trash").dir("/Users/me/work")
        fs.file("/Users/me/work/big.mov", allocated: 5_000).file("/Users/me/work/a.bin", allocated: 10)
        let trasher = RecordingTrasher(fileSystem: fs)
        let coordinator = ScanCoordinator(provider: fs)
        let scope = ScanScope(rootPath: "/Users/me/work", kind: .folder)!
        let first = try coordinator.start(scope: scope)
        _ = await first.waitUntilFinished()
        let service = ItemActionService(coordinator: coordinator, provider: fs, trasher: trasher, policy: TrashPolicy(homeDirectory: "/Users/me"))
        let bigID = first.store.children(of: first.store.rootID!).items.first { $0.name == "big.mov" }!.id
        let candidate = try service.candidate(for: bigID, in: first).get()
        _ = try service.moveToTrash(candidate, in: first).get()
        XCTAssertEqual(first.store.item(first.store.rootID!)!.sizeSummary.knownAllocatedBytes, 5_010, "移動した分を即時に差し引かない")

        let second = try coordinator.start(scope: scope)
        let result = await second.waitUntilFinished()
        XCTAssertFalse(result.isStale)
        XCTAssertEqual(second.store.item(second.store.rootID!)!.sizeSummary.knownAllocatedBytes, 10, "再スキャンで新しい結果に置き換わる")
        XCTAssertEqual(service.candidate(for: bigID, in: first), .failure(.notInCurrentResult))
    }

    // MARK: - 集計と部分結果

    /// どの時点でキャンセルしても、確定後の結果に矛盾がない。
    func testEveryCancellationPointLeavesConsistentPartialResult() {
        func makeTree() -> MockFileSystem {
            let fs = MockFileSystem()
            fs.dir("/r")
            for a in 0..<3 {
                fs.dir("/r/a\(a)")
                for b in 0..<3 {
                    fs.dir("/r/a\(a)/b\(b)")
                    for c in 0..<3 {
                        fs.file("/r/a\(a)/b\(b)/f\(c)", allocated: Int64(100 * (a + 1) + 10 * b + c))
                    }
                }
            }
            fs.dir("/r/locked")
            fs.denyListing("/r/locked")
            fs.interruptListing("/r/a1/b1", after: 1)
            return fs
        }
        for limit in 0..<60 {
            let fs = makeTree()
            let scope = ScanScope(rootPath: "/r", kind: .folder)!
            let store = ScanStore(rootPath: scope.rootPath)
            var calls = 0
            let termination = FileSystemScanner(scope: scope, provider: fs, batchSize: 4).run(into: store) {
                calls += 1
                return calls > limit
            }
            store.finalize()

            var stack = [store.rootID!]
            var fileTotal: Int64 = 0
            while let id = stack.popLast() {
                let item = store.item(id)!
                XCTAssertNotEqual(item.traversalState, .pending, "確定後に走査中のフォルダを残さない（limit \(limit)）")
                if item.kind == .file {
                    fileTotal += item.allocatedSize ?? 0
                }
                stack.append(contentsOf: store.children(of: id).items.map(\.id))
            }
            let root = store.item(store.rootID!)!
            XCTAssertEqual(root.sizeSummary.knownAllocatedBytes, fileTotal, "集計が保存したファイルの合計と一致する（limit \(limit)）")
            XCTAssertEqual(store.locatedItems(.problems).totalCount, store.currentCounts.problemItems)
            if termination == .cancelled {
                XCTAssertEqual(root.traversalState, .partial)
                XCTAssertTrue(root.sizeSummary.hasUnvisitedDescendants || root.sizeSummary.unreadableLocations > 0)
            }
        }
    }

    /// キャンセルと完了が競合しても、終端は一度だけ決まり、最後のイベントと結果が一致する。
    func testCancelRacingCompletionSettlesOnce() async throws {
        let fs = MockFileSystem()
        fs.dir("/r")
        for d in 0..<10 {
            fs.dir("/r/d\(d)")
            for f in 0..<20 {
                fs.file("/r/d\(d)/f\(f)", allocated: 1)
            }
        }
        var configuration = ScanCoordinator.Configuration()
        configuration.notifyInterval = 0.005
        configuration.batchSize = 5
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration)
        for iteration in 0..<30 {
            let session = try coordinator.start(scope: ScanScope(rootPath: "/r", kind: .folder)!)
            let updates = session.makeUpdates()
            let delay = UInt64(iteration % 4) * 300_000
            Task.detached {
                try? await Task.sleep(nanoseconds: delay)
                session.cancel()
            }
            var events: [ScanProgress] = []
            for await progress in updates {
                events.append(progress)
            }
            let result = await session.waitUntilFinished()
            XCTAssertEqual(events.filter { $0.state.isTerminal }.count, 1)
            XCTAssertEqual(events.last?.state, result.state)
            XCTAssertTrue([.completed, .cancelled].contains(result.state), "\(result.state)")
            if result.state == .completed {
                XCTAssertEqual(result.counts.files, 200)
            }
        }
    }

    func testHardLinkedFilesAreCountedPerPath() {
        let fs = MockFileSystem()
        fs.dir("/r").file("/r/a", allocated: 100, inode: 7).file("/r/b", allocated: 100, inode: 7)
        let scope = ScanScope(rootPath: "/r", kind: .folder)!
        let store = ScanStore(rootPath: scope.rootPath)
        _ = FileSystemScanner(scope: scope, provider: fs).run(into: store)
        store.finalize()
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 200, "初版はパス単位で数える")
        XCTAssertEqual(store.largestFiles().totalCount, 2)
        XCTAssertEqual(store.currentCounts.excludedItems, 0, "ファイルのハードリンクは除外しない")
    }

    func testTerminalStateClassification() async throws {
        func finalState(_ build: (MockFileSystem) -> Void) async throws -> ScanState {
            let fs = MockFileSystem(rootDevice: 1)
            fs.dir("/r").file("/r/ok", allocated: 1)
            build(fs)
            let session = try ScanCoordinator(provider: fs).start(scope: ScanScope(rootPath: "/r", kind: .folder)!)
            return await session.waitUntilFinished().state
        }
        let excludedOnly = try await finalState { $0.dir("/r/mnt", device: 2) }
        XCTAssertEqual(excludedOnly, .completed, "方針による除外だけなら完了")
        let unknownSize = try await finalState { $0.file("/r/u", allocated: nil) }
        XCTAssertEqual(unknownSize, .completedWithErrors)
        let cloudOnly = try await finalState { $0.dir("/r/cloud", isDataless: true) }
        XCTAssertEqual(cloudOnly, .completedWithErrors)
    }

    func testUsedBytesNeedsBothValues() {
        let now = Date()
        XCTAssertEqual(VolumeCapacity(volumeName: nil, totalBytes: 100, availableBytes: 40, fetchedAt: now).usedBytes, 60)
        XCTAssertNil(VolumeCapacity(volumeName: nil, totalBytes: 100, availableBytes: nil, fetchedAt: now).usedBytes)
        XCTAssertNil(VolumeCapacity(volumeName: nil, totalBytes: 10, availableBytes: 40, fetchedAt: now).usedBytes)
    }

    // MARK: - 問い合わせ

    func testQueryCachesFollowNewRevisions() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        let a = b.add("a", .directory, parent: root)
        let bDir = b.add("b", .directory, parent: root)
        b.add("a1", .file, parent: a, allocated: 100)
        b.add("b1", .file, parent: bDir, allocated: 10)
        let store = ScanStore(rootPath: "/root", provisionalFileLimit: 10)
        store.apply(b.take())
        XCTAssertEqual(store.children(of: root).items.map(\.id), [a, bDir])
        XCTAssertEqual(store.largestFiles().items.first?.name, "a1")

        b.add("b2", .file, parent: bDir, allocated: 1_000)
        store.apply(b.take())
        XCTAssertEqual(store.children(of: root).items.map(\.id), [bDir, a], "版が進んだら並べ直す")
        XCTAssertEqual(store.position(of: bDir, in: root), 0)
        XCTAssertEqual(store.largestFiles().items.first?.name, "b2", "暫定の上位も新しい版に追従する")
    }

    func testTreemapOthersMapToListRows() {
        var b = RecordBuilder()
        let root = b.add("root", .directory, parent: nil)
        for i in 0..<440 {
            b.add(String(format: "f%03d", i), .file, parent: root, allocated: Int64(10_000 - i))
        }
        b.add("zero", .file, parent: root, allocated: 0)
        b.add("unknown", .file, parent: root, allocated: nil)
        b.add("mnt", .directory, parent: root, exclusion: .otherVolume)
        b.listed(root)
        let store = ScanStore(rootPath: "/root")
        store.apply(b.take())

        let data = store.childrenForTreemap(of: root, limit: 400)
        XCTAssertEqual(data.remainderCount, 40, "面積を持つ省いた項目だけを数える")
        let result = TreemapLayout.layout(
            data.page.items.map { (id: $0.id, bytes: $0.displayAllocatedBytes) },
            in: TreemapRect(x: 0, y: 0, width: 800, height: 600),
            minimumTileArea: 48, maximumTiles: 400,
            remainder: (data.remainderCount, data.remainderKnownBytes)
        )
        let firstHidden = store.children(of: root, offset: result.itemTileCount, limit: 1).items.first
        let drawn = Set(result.tiles.compactMap { tile -> ItemID? in
            if case .item(let id) = tile.content { return id } else { return nil }
        })
        XCTAssertNotNil(firstHidden)
        XCTAssertFalse(drawn.contains(firstHidden!.id), "「その他」の先頭は描かれなかった最大の項目")
        XCTAssertEqual(store.children(of: root).totalCount, 443, "0・不明・除外も一覧からは到達できる")
    }

    // MARK: - 実ファイルシステム

    func testPOSIXListingRefusesSwappedDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-swap-\(UUID().uuidString)")
        let a = base.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fs = POSIXFileSystem()
        let original = try XCTUnwrap(try fs.metadata(atPath: a.path).get().identity)

        // 削除直後に作り直すと同じ inode が再利用されることがあるため、新しいフォルダを先に作ってから入れ替える
        let replacement = base.appendingPathComponent("a-new")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.moveItem(at: replacement, to: a)
        guard case .failure(let replaced) = fs.listDirectory(atPath: a.path, expectedIdentity: original) else {
            return XCTFail("別の実体に置き換わったフォルダは開かない")
        }
        XCTAssertEqual(replaced.kind, .changed)

        let other = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: other)
        guard case .failure(let linked) = fs.listDirectory(atPath: a.path, expectedIdentity: nil) else {
            return XCTFail("リンクを辿って開かない")
        }
        XCTAssertEqual(linked.kind, .changed)
    }

    func testSparseFileKeepsLogicalAndAllocatedSeparate() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-sparse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("sparse.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_000_000_000)
        try handle.close()

        let metadata = try POSIXFileSystem().metadata(atPath: file.path).get()
        XCTAssertEqual(metadata.logicalSize, 1_000_000_000)
        let allocated = try XCTUnwrap(metadata.allocatedSize)
        guard allocated < 1_000_000_000 else {
            throw XCTSkip("このファイルシステムは sparse file に対応していない")
        }
        let scope = ScanScope(rootPath: base.path, kind: .folder)!
        let store = ScanStore(rootPath: scope.rootPath)
        _ = FileSystemScanner(scope: scope).run(into: store)
        let root = store.item(store.rootID!)!
        XCTAssertEqual(root.sizeSummary.knownLogicalBytes, 1_000_000_000)
        XCTAssertEqual(root.sizeSummary.knownAllocatedBytes, allocated, "論理サイズで割り当て済みサイズを代用しない")
    }

    // MARK: - 走査スレッドの準備

    func testPrepareScanningThreadRunsFirstOnTheScanningThread() {
        let base = MockFileSystem()
        base.dir("/r").dir("/r/a").file("/r/a/f", allocated: 1)
        let recorder = RecordingProvider(base: base)
        let scope = ScanScope(rootPath: "/r", kind: .folder)!
        let store = ScanStore(rootPath: scope.rootPath)
        let done = expectation(description: "scan")
        Thread {
            _ = FileSystemScanner(scope: scope, provider: recorder).run(into: store)
            done.fulfill()
        }.start()
        wait(for: [done], timeout: 5)
        let calls = recorder.calls
        XCTAssertEqual(calls.first?.name, "prepare", "取得抑止の設定を最初に行う")
        XCTAssertEqual(calls.filter { $0.name == "prepare" }.count, 1)
        XCTAssertEqual(Set(calls.map(\.thread)).count, 1, "設定はスレッド単位なので、同じスレッドで列挙する")
    }
}

/// 呼び出しの順序とスレッドを記録する。
private final class RecordingProvider: FileSystemProvider, @unchecked Sendable {
    private let base: MockFileSystem
    private let lock = NSLock()
    private var recorded: [(name: String, thread: String)] = []

    init(base: MockFileSystem) {
        self.base = base
    }

    var calls: [(name: String, thread: String)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ name: String) {
        let thread = "\(Unmanaged.passUnretained(Thread.current).toOpaque())"
        lock.lock()
        recorded.append((name, thread))
        lock.unlock()
    }

    func prepareScanningThread() {
        record("prepare")
    }

    func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError> {
        record("metadata")
        return base.metadata(atPath: path)
    }

    func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError> {
        record("list")
        return base.listDirectory(atPath: path, expectedIdentity: expectedIdentity)
    }
}
