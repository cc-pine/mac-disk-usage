import XCTest
@testable import DiskUsageCore

final class FileSystemScannerTests: XCTestCase {
    private func scan(_ fs: MockFileSystem, root: String = "/", kind: ScanScope.Kind = .folder,
                      allowed: Set<UInt64> = [], excluded: Set<String> = [],
                      isCancelled: () -> Bool = { false }) -> (ScanStore, ScanTermination) {
        let scope = ScanScope(rootPath: root, kind: kind, allowedDevices: allowed, excludedPaths: excluded)!
        let store = ScanStore(rootPath: scope.rootPath)
        let scanner = FileSystemScanner(scope: scope, provider: fs, batchSize: 3)
        let termination = scanner.run(into: store, isCancelled: isCancelled)
        store.finalize()
        return (store, termination)
    }

    private func child(_ store: ScanStore, _ path: String) -> ScanItem? {
        var current = store.rootID!
        for name in PathUtilities.components(of: path) {
            guard let next = store.children(of: current).items.first(where: { $0.name == name }) else { return nil }
            current = next.id
        }
        return store.item(current)
    }

    func testScansNestedTreeAndAggregates() {
        let fs = MockFileSystem()
        fs.dir("/a").dir("/a/b").file("/a/b/x", allocated: 100).file("/a/y", allocated: 50)
        fs.file("/.hidden", allocated: 7)
        let (store, termination) = scan(fs)
        XCTAssertEqual(termination, .finished)
        let root = store.item(store.rootID!)!
        XCTAssertEqual(root.sizeSummary.knownAllocatedBytes, 157)
        XCTAssertEqual(root.traversalState, .complete)
        XCTAssertEqual(child(store, "/.hidden")?.allocatedSize, 7, "隠しファイルも列挙する")
        XCTAssertEqual(store.currentCounts.files, 3)
        XCTAssertEqual(store.currentCounts.directories, 3)
    }

    func testDoesNotFollowSymlinks() {
        let fs = MockFileSystem()
        fs.dir("/real").file("/real/big", allocated: 1_000).link("/alias")
        let (store, _) = scan(fs)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 1_000)
        XCTAssertEqual(child(store, "/alias")?.kind, .symbolicLink)
        XCTAssertFalse(fs.listedPaths.contains("/alias"))
    }

    func testDeniedDirectoryDoesNotStopScan() {
        let fs = MockFileSystem()
        fs.dir("/locked").file("/locked/secret", allocated: 999).dir("/open").file("/open/f", allocated: 1)
        fs.denyListing("/locked")
        let (store, termination) = scan(fs)
        XCTAssertEqual(termination, .finished)
        let locked = child(store, "/locked")!
        XCTAssertEqual(locked.accessState, .denied)
        XCTAssertNil(locked.displayAllocatedBytes, "読めないフォルダを 0 bytes と表示しない")
        XCTAssertEqual(child(store, "/open/f")?.allocatedSize, 1)
        let root = store.item(store.rootID!)!
        XCTAssertEqual(root.sizeSummary.unreadableLocations, 1)
        XCTAssertEqual(root.traversalState, .partial)
    }

    func testVanishedItemIsRecordedAsError() {
        let fs = MockFileSystem()
        fs.file("/gone", allocated: 5).file("/ok", allocated: 3)
        fs.failMetadata("/gone")
        let (store, _) = scan(fs)
        let gone = child(store, "/gone")!
        XCTAssertEqual(gone.accessState, .error)
        XCTAssertEqual(store.currentCounts.problemItems, 1)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 3)
    }

    func testInterruptedListingKeepsPartialResults() {
        let fs = MockFileSystem()
        fs.dir("/big").file("/big/1", allocated: 1).file("/big/2", allocated: 2).file("/big/3", allocated: 3)
        fs.interruptListing("/big", after: 2)
        let (store, termination) = scan(fs)
        XCTAssertEqual(termination, .finished)
        let big = child(store, "/big")!
        XCTAssertEqual(big.traversalState, .partial)
        XCTAssertEqual(big.sizeSummary.knownAllocatedBytes, 3)
        XCTAssertEqual(big.displayAllocatedBytes, 3)
        XCTAssertTrue(big.sizeSummary.hasUnvisitedDescendants, "列挙しきれなかった項目がある")
        XCTAssertTrue(store.item(store.rootID!)!.sizeSummary.hasUnvisitedDescendants)
    }

    func testDoesNotEnterOtherVolumes() {
        let fs = MockFileSystem(rootDevice: 1)
        fs.dir("/mnt", device: 2).file("/mnt/huge", allocated: 1_000_000, device: 2)
        fs.file("/local", allocated: 10)
        let (store, _) = scan(fs)
        let mount = child(store, "/mnt")!
        XCTAssertEqual(mount.traversalState, .excluded)
        XCTAssertEqual(mount.exclusionReason, .otherVolume)
        XCTAssertNil(mount.displayAllocatedBytes)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 10)
        XCTAssertEqual(store.currentCounts.excludedItems, 1)
        XCTAssertFalse(fs.listedPaths.contains("/mnt"))
    }

    func testStartupDiskAllowsDataVolumeAndExcludesAliases() {
        // System = device 1, Data = device 2（firmlink で /Users が Data 側に見える）
        let fs = MockFileSystem(rootDevice: 1)
        fs.dir("/System").dir("/System/Volumes").dir("/System/Volumes/Data", device: 2, inode: 500)
        fs.dir("/System/Volumes/Data/Users", device: 2, inode: 600)
        fs.dir("/Users", device: 2, inode: 600).file("/Users/me.mov", allocated: 4_000, device: 2)
        fs.dir("/Volumes").dir("/Volumes/External", device: 3)
        fs.file("/System/kernel", allocated: 100)
        let (store, termination) = scan(
            fs, kind: .startupDisk, allowed: [1, 2],
            excluded: ["/System/Volumes", "/Volumes", "/dev"]
        )
        XCTAssertEqual(termination, .finished)
        XCTAssertEqual(child(store, "/Users")?.traversalState, .complete)
        XCTAssertEqual(child(store, "/System/Volumes")?.exclusionReason, .scopeRule)
        XCTAssertEqual(child(store, "/Volumes")?.exclusionReason, .scopeRule)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 4_100, "Data 側を二重に数えない")
    }

    func testDuplicateDirectoryPathIsExcluded() {
        let fs = MockFileSystem()
        fs.dir("/a", inode: 50).file("/a/f", allocated: 10)
        fs.dir("/b", inode: 50)  // 同じ (device, inode) への別経路
        let (store, _) = scan(fs)
        XCTAssertEqual(child(store, "/b")?.exclusionReason, .duplicatePath)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 10)
    }

    func testRootExclusionRulesDoNotExcludeSelectedRoot() {
        let fs = MockFileSystem()
        fs.dir("/Volumes").dir("/Volumes/Ext", device: 3).file("/Volumes/Ext/f", allocated: 9, device: 3)
        let (store, termination) = scan(fs, root: "/Volumes/Ext", kind: .volume, excluded: ["/Volumes"])
        XCTAssertEqual(termination, .finished)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 9)
        XCTAssertEqual(store.path(of: store.rootID!), "/Volumes/Ext")
    }

    func testRootFailure() {
        let fs = MockFileSystem()
        let (store, termination) = scan(fs, root: "/missing")
        guard case .rootFailed(let error) = termination else {
            return XCTFail("ルート失敗を返す")
        }
        XCTAssertEqual(error.kind, .notFound)
        XCTAssertEqual(store.itemCount, 1)
        XCTAssertNil(store.item(store.rootID!)!.displayAllocatedBytes)
    }

    func testCancellationStopsEnumerationAndKeepsResults() {
        let fs = MockFileSystem()
        fs.dir("/a").file("/a/1", allocated: 1).dir("/b").file("/b/2", allocated: 2).dir("/c")
        var checks = 0
        let (store, termination) = scan(fs) {
            checks += 1
            return checks > 4
        }
        XCTAssertEqual(termination, .cancelled)
        let root = store.item(store.rootID!)!
        XCTAssertEqual(root.traversalState, .partial)
        XCTAssertTrue(root.sizeSummary.hasUnvisitedDescendants)
        XCTAssertLessThan(fs.listedPaths.count, 4)
    }

    func testDeepHierarchyDoesNotRecurse() {
        let fs = MockFileSystem()
        var path = ""
        for i in 0..<5_000 {
            path += "/d\(i)"
            fs.dir(path)
        }
        fs.file(path + "/leaf", allocated: 42)
        let (store, termination) = scan(fs)
        XCTAssertEqual(termination, .finished)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 42)
        XCTAssertEqual(store.item(store.rootID!)!.traversalState, .complete)
    }

    func testUnlistableRootIsRootFailure() {
        let fs = MockFileSystem()
        fs.dir("/Desktop").file("/Desktop/a", allocated: 1)
        fs.denyListing("/Desktop")
        let (store, termination) = scan(fs, root: "/Desktop")
        guard case .rootFailed(let error) = termination else {
            return XCTFail("ルートを列挙できなければ失敗にする")
        }
        XCTAssertEqual(error.kind, .permissionDenied)
        XCTAssertEqual(store.item(store.rootID!)!.accessState, .denied)
    }

    func testMetadataFailureCountsAsUnknownNotZero() {
        let fs = MockFileSystem()
        fs.dir("/ro").file("/ro/a", allocated: 100).file("/ro/b", allocated: 100)
        fs.failMetadata("/ro/a")
        let (store, _) = scan(fs)
        let ro = child(store, "/ro")!
        XCTAssertEqual(ro.sizeSummary.knownAllocatedBytes, 100)
        XCTAssertEqual(ro.sizeSummary.unknownAllocatedItems, 1)
        XCTAssertTrue(ro.isSizeIncomplete)
        XCTAssertEqual(store.currentCounts.otherItems, 0, "種類不明の項目を特殊ファイルとして数えない")
        XCTAssertTrue(child(store, "/ro/a")!.isSizeIncomplete)
    }

    func testCloudOnlyDirectoryIsNotListed() {
        let fs = MockFileSystem()
        fs.dir("/iCloud", isDataless: true).file("/iCloud/remote", allocated: 0, logical: 9_000_000)
        fs.file("/local", allocated: 10)
        let (store, termination) = scan(fs)
        XCTAssertEqual(termination, .finished)
        XCTAssertFalse(fs.listedPaths.contains("/iCloud"), "列挙するとダウンロードが始まる")
        let cloud = child(store, "/iCloud")!
        XCTAssertEqual(cloud.accessState, .notScanned)
        XCTAssertNil(cloud.displayAllocatedBytes)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.unreadableLocations, 1)
    }

    func testDirectoryReplacedDuringScanIsNotEntered() {
        let fs = MockFileSystem()
        fs.dir("/a", inode: 70).file("/a/x", allocated: 5)
        fs.onList = { @Sendable path in
            if path == "/a" {
                // ルートの列挙で識別情報を記録した後、/a を開く直前に別の実体へ置き換わる
                fs.replace("/a", with: FileMetadata(kind: .directory, identity: FileIdentity(device: 1, inode: 71)))
            }
        }
        let (store, _) = scan(fs)
        let a = child(store, "/a")!
        XCTAssertEqual(a.accessState, .error)
        XCTAssertEqual(a.traversalState, .partial)
        XCTAssertNil(child(store, "/a/x"))
    }

    func testStartupScopeAlwaysAllowsRootDevice() {
        let fs = MockFileSystem(rootDevice: 1)
        fs.dir("/Users", device: 1).file("/Users/f", allocated: 3, device: 1)
        let (store, _) = scan(fs, kind: .startupDisk, allowed: [2])
        XCTAssertEqual(child(store, "/Users")?.traversalState, .complete)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.knownAllocatedBytes, 3)
    }

    func testRealPermissionDeniedDirectory() throws {
        #if os(Linux) || os(macOS)
        guard getuid() != 0 else { throw XCTSkip("root では権限拒否を再現できない") }
        #endif
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-\(UUID().uuidString)")
        let locked = base.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 10).write(to: locked.appendingPathComponent("secret"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: base)
        }
        let scope = ScanScope(rootPath: base.path, kind: .folder)!
        let store = ScanStore(rootPath: scope.rootPath)
        XCTAssertEqual(FileSystemScanner(scope: scope).run(into: store), .finished)
        store.finalize()
        let lockedItem = store.children(of: store.rootID!).items.first { $0.name == "locked" }!
        XCTAssertEqual(lockedItem.accessState, .denied)
        XCTAssertEqual(store.item(store.rootID!)!.sizeSummary.unreadableLocations, 1)
    }

    func testScopeRejectsUnsafeRoots() {
        XCTAssertNil(ScanScope(rootPath: "", kind: .folder))
        XCTAssertNil(ScanScope(rootPath: "relative/path", kind: .folder))
        XCTAssertNil(ScanScope(rootPath: "/a/../b", kind: .folder))
        XCTAssertNotNil(ScanScope(rootPath: "/a/b/", kind: .folder))
    }

    func testRealFileSystemSmoke() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: base.appendingPathComponent("sub/data.bin"))
        try Data().write(to: base.appendingPathComponent("empty.txt"))
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("sub")
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let scope = ScanScope(rootPath: base.path, kind: .folder)!
        let store = ScanStore(rootPath: scope.rootPath)
        let termination = FileSystemScanner(scope: scope).run(into: store)
        store.finalize()
        XCTAssertEqual(termination, .finished)
        let root = store.item(store.rootID!)!
        XCTAssertEqual(root.sizeSummary.knownLogicalBytes, 10_000)
        XCTAssertGreaterThan(root.sizeSummary.knownAllocatedBytes, 0, "書き込んだ 10 KB 分の領域が割り当てられる")
        XCTAssertEqual(root.sizeSummary.unknownAllocatedItems, 0)
        XCTAssertEqual(store.currentCounts.symbolicLinks, 1)
        XCTAssertEqual(store.currentCounts.files, 2)
        XCTAssertEqual(root.traversalState, .complete)
    }
}
