import XCTest
@testable import DiskUsageCore

/// 模擬ファイルシステム上で、項目を ~/.Trash へ移す模擬のゴミ箱。
final class RecordingTrasher: Trasher, @unchecked Sendable {
    private let lock = NSLock()
    private let fileSystem: MockFileSystem
    private(set) var paths: [String] = []
    var error: Error?
    /// false にすると、移動先を読めない（~/.Trash にアクセスできない）状況を再現する
    var placeInTrash = true
    /// 設定すると、移動先として別の実体を置く（取り違えや inode の変化の再現用）
    var substitute: FileMetadata?
    /// true にすると、元の項目を残したまま成功を返す（別の項目が移動された状況の再現用）
    var leaveOriginal = false
    /// 設定すると、参照が別の場所を指していることにする（参照作成後の差し替えの再現用）
    var resolvedPathOverride: String?

    init(fileSystem: MockFileSystem) {
        self.fileSystem = fileSystem
    }

    func currentPath(of target: TrashTarget) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedPathOverride ?? target.path
    }

    func moveToTrash(_ target: TrashTarget) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw error
        }
        let path = target.path
        paths.append(path)
        let trashed = "/Users/me/.Trash/" + PathUtilities.lastComponent(of: path)
        if !leaveOriginal, case .success(let metadata) = fileSystem.metadata(atPath: path) {
            fileSystem.remove(path)
            if placeInTrash {
                fileSystem.place(trashed, substitute ?? metadata)
            }
        }
        return trashed
    }
}

final class ItemActionServiceTests: XCTestCase {
    private var fs: MockFileSystem!
    private var trasher: RecordingTrasher!
    private var coordinator: ScanCoordinator!

    override func setUp() {
        fs = MockFileSystem()
        fs.dir("/Users").dir("/Users/me").dir("/Users/me/work", inode: 900)
        fs.file("/Users/me/work/big.mov", allocated: 5_000, inode: 901)
        fs.dir("/Users/me/work/sub").file("/Users/me/work/sub/a.bin", allocated: 10)
        fs.link("/Users/me/work/link")
        fs.dir("/Users/me/work/App.app", isPackage: true).file("/Users/me/work/App.app/inner", allocated: 1)
        fs.dir("/Users/me/Library").file("/Users/me/Library/prefs.plist", allocated: 1)
        fs.dir("/Users/me/.Trash").file("/Users/me/.Trash/old", allocated: 1)
        fs.dir("/Users/other").dir("/Users/other/Library").file("/Users/other/Library/x", allocated: 1)
        fs.dir("/Library").file("/Library/x", allocated: 1)
        fs.dir("/Volumes").dir("/Volumes/Ext", device: 3).dir("/Volumes/Ext/.Trashes", device: 3)
        fs.file("/Volumes/Ext/.Trashes/t", allocated: 1, device: 3).file("/Volumes/Ext/movie.mov", allocated: 9, device: 3)
        trasher = RecordingTrasher(fileSystem: fs)
        coordinator = ScanCoordinator(provider: fs)
    }

    private func completedSession(root: String) async throws -> ScanSession {
        let session = try coordinator.start(scope: ScanScope(rootPath: root, kind: .folder)!)
        _ = await session.waitUntilFinished()
        return session
    }

    private func service() -> ItemActionService {
        ItemActionService(coordinator: coordinator, provider: fs, trasher: trasher, policy: TrashPolicy(homeDirectory: "/Users/me"))
    }

    private func id(_ session: ScanSession, _ path: String) -> ItemID {
        let store = session.store
        let root = session.scope.rootPath
        var current = store.rootID!
        let relative = PathUtilities.components(of: path).dropFirst(PathUtilities.components(of: root).count)
        for name in relative {
            current = store.children(of: current).items.first { $0.name == name }!.id
        }
        return current
    }

    func testMovesRegularFileAndMarksStale() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        XCTAssertEqual(candidate.path, "/Users/me/work/big.mov")
        XCTAssertEqual(candidate.allocatedSize, 5_000)

        let outcome = service.moveToTrash(candidate, in: session)
        XCTAssertNotNil(try? outcome.get())
        XCTAssertEqual(trasher.paths, ["/Users/me/work/big.mov"])
        XCTAssertTrue(session.result.isStale)
        XCTAssertEqual(session.result.state, .completed, "走査完了という事実は変えない")
        XCTAssertEqual(service.candidate(for: candidate.itemID, in: session), .failure(.alreadyMoved))
        XCTAssertEqual(session.store.item(session.store.rootID!)!.sizeSummary.knownAllocatedBytes, 5_011, "集計を即時に差し引かない")
    }

    func testRejectsNonFilesRootAndPackageInterior() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        XCTAssertEqual(service.candidate(for: session.store.rootID!, in: session), .failure(.scanRoot))
        XCTAssertEqual(service.candidate(for: id(session, "/Users/me/work/sub"), in: session), .failure(.notRegularFile))
        XCTAssertEqual(service.candidate(for: id(session, "/Users/me/work/link"), in: session), .failure(.notRegularFile))
        XCTAssertEqual(service.candidate(for: id(session, "/Users/me/work/App.app/inner"), in: session), .failure(.insidePackage))
    }

    func testRejectsWhenPackageIsAboveScanRoot() async throws {
        let session = try await completedSession(root: "/Users/me/work/App.app")
        let service = service()
        XCTAssertEqual(service.candidate(for: id(session, "/Users/me/work/App.app/inner"), in: session), .failure(.insidePackage))
    }

    func testRejectsProtectedLocationsCaseInsensitively() async throws {
        let session = try await completedSession(root: "/")
        let service = service()
        XCTAssertEqual(service.candidate(for: id(session, "/Library/x"), in: session), .failure(.protectedLocation("/Library")))
        XCTAssertEqual(
            service.candidate(for: id(session, "/Users/me/Library/prefs.plist"), in: session),
            .failure(.protectedLocation("/Users/*/Library"))
        )
        XCTAssertNotNil(TrashPolicy(homeDirectory: "/Users/me").protectedRoot(containing: "/library/X"))
        XCTAssertNil(TrashPolicy(homeDirectory: "/Users/me").protectedRoot(containing: "/Users/me/LibraryX/a"))
    }

    func testProtectsTrashOtherUsersLibraryAndOtherVolumeSystemAreas() async throws {
        let session = try await completedSession(root: "/")
        let service = service()
        XCTAssertEqual(service.candidate(for: id(session, "/Users/me/.Trash/old"), in: session), .failure(.protectedLocation("/Users/*/.Trash")))
        XCTAssertEqual(service.candidate(for: id(session, "/Users/other/Library/x"), in: session), .failure(.protectedLocation("/Users/*/Library")))

        let volume = try await completedSession(root: "/Volumes/Ext")
        XCTAssertEqual(
            service.candidate(for: id(volume, "/Volumes/Ext/.Trashes/t"), in: volume),
            .failure(.protectedLocation("/Volumes/*/.Trashes"))
        )
        XCTAssertNotNil(try? service.candidate(for: id(volume, "/Volumes/Ext/movie.mov"), in: volume).get(), "外付けの通常ファイルは移動できる")
        let policy = TrashPolicy(homeDirectories: ["/Users/me", "/Volumes/Home/me"])
        XCTAssertNotNil(policy.protectedRoot(containing: "/Volumes/Home/me/Library/a"), "ホームの実体パスも保護する")
        XCTAssertNotNil(policy.protectedRoot(containing: "/System/Volumes/Data/Users/me/x"))
    }

    func testVerifiesTrashedItemIdentity() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        let outcome = try service.moveToTrash(candidate, in: session).get()
        XCTAssertTrue(outcome.isVerified)
    }

    func testUnverifiableTrashIsReportedAsUnverified() async throws {
        // 移動先を読めない（模擬ファイルシステムに移動先がない）
        trasher.placeInTrash = false
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        let outcome = try service.moveToTrash(candidate, in: session).get()
        XCTAssertFalse(outcome.isVerified)
        XCTAssertTrue(service.isMoved(candidate.itemID, in: session))
    }

    func testDetectsWrongItemInTrash() async throws {
        trasher.substitute = FileMetadata(kind: .file, logicalSize: 1, allocatedSize: 1, identity: FileIdentity(device: 1, inode: 777_777))
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        guard case .failure(.unexpectedItemMoved) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("ゴミ箱の項目が確認した実体と違えば知らせる")
        }
        XCTAssertTrue(service.isMoved(candidate.itemID, in: session), "移動自体は起きたものとして扱う")
        XCTAssertTrue(session.result.isStale)
    }

    func testOriginalStillPresentIsReportedAndNotMarkedMoved() async throws {
        trasher.leaveOriginal = true
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        guard case .failure(.unexpectedItemMoved) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("確認した項目が元の場所に残っていれば知らせる")
        }
        XCTAssertFalse(service.isMoved(candidate.itemID, in: session), "残っている項目を移動済みにしない")
        XCTAssertTrue(session.result.isStale, "何かが移動した可能性があるため結果は古いものとする")
    }

    func testInodeChangeOnMoveIsUnverifiedNotAlarm() async throws {
        // FAT などでは移動で inode が変わる。名前・サイズ・更新日時が同じなら取り違えとはしない
        let original = try fs.metadata(atPath: "/Users/me/work/big.mov").get()
        var moved = original
        moved.identity = FileIdentity(device: 1, inode: 999_999)
        trasher.substitute = moved
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        let outcome = try service.moveToTrash(candidate, in: session).get()
        XCTAssertFalse(outcome.isVerified)
    }

    func testReferencePointingElsewhereAborts() async throws {
        trasher.resolvedPathOverride = "/Users/me/Library/prefs.plist"
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("参照が確認した場所を指していなければ中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
    }

    func testAncestorAboveRootReplacedBySymlinkAborts() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        // スキャン対象を含むツリーごと別の場所へ移され、元の場所にリンクが置かれた
        fs.replace("/Users/me", with: FileMetadata(kind: .symbolicLink, identity: FileIdentity(device: 1, inode: 31_337)))
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("スキャン対象より上のフォルダの差し替えを検知して中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
    }

    func testUnreadableDuringVerificationIsCannotVerify() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/sub/a.bin"), in: session).get()
        fs.failMetadata("/Users/me/work/sub", error: FileSystemError(kind: .permissionDenied, code: 13, message: "アクセスが拒否されました"))
        guard case .failure(.cannotVerify) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("読み取れないことを「変わった」と言わない")
        }
    }

    func testVolumeRulesApplyWhenScanRootIsInsideMount() async throws {
        // /Users/me/work/disk に別ボリューム（device 5）があり、その中の Users をスキャンする
        fs.dir("/Users/me/work/disk", device: 5).dir("/Users/me/work/disk/Users", device: 5)
        fs.dir("/Users/me/work/disk/Users/bob", device: 5).dir("/Users/me/work/disk/Users/bob/Library", device: 5)
        fs.file("/Users/me/work/disk/Users/bob/Library/x", allocated: 1, device: 5)
        let session = try await completedSession(root: "/Users/me/work/disk/Users")
        let service = service()
        XCTAssertEqual(
            service.candidate(for: id(session, "/Users/me/work/disk/Users/bob/Library/x"), in: session),
            .failure(.protectedLocation("/Users/me/work/disk/Users/*/Library"))
        )
    }

    func testVolumeRulesApplyToMountsOutsideVolumesFolder() async throws {
        // /Users/me/work/disk に別ボリューム（device 5）がマウントされている
        fs.dir("/Users/me/work/disk", device: 5).dir("/Users/me/work/disk/.Trashes", device: 5)
        fs.file("/Users/me/work/disk/.Trashes/t", allocated: 1, device: 5).file("/Users/me/work/disk/data.bin", allocated: 1, device: 5)
        let session = try await completedSession(root: "/Users/me/work/disk")
        let service = service()
        XCTAssertEqual(
            service.candidate(for: id(session, "/Users/me/work/disk/.Trashes/t"), in: session),
            .failure(.protectedLocation("/Users/me/work/disk/.Trashes"))
        )
        XCTAssertNotNil(try? service.candidate(for: id(session, "/Users/me/work/disk/data.bin"), in: session).get())
    }

    func testRejectsHardLinkedFiles() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        var metadata = try fs.metadata(atPath: "/Users/me/work/big.mov").get()
        metadata.linkCount = 2
        fs.replace("/Users/me/work/big.mov", with: metadata)
        XCTAssertEqual(service().candidate(for: id(session, "/Users/me/work/big.mov"), in: session), .failure(.multipleHardLinks))
    }

    func testOldSessionIsRejectedAfterRescanAndScanWaitsForTrash() async throws {
        let first = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(first, "/Users/me/work/big.mov"), in: first).get()
        let second = try await completedSession(root: "/Users/me/work")
        XCTAssertEqual(service.moveToTrash(candidate, in: first), .failure(.blocked(.notInCurrentResult)))
        XCTAssertEqual(service.moveToTrash(candidate, in: second), .failure(.blocked(.notInCurrentResult)))
        XCTAssertTrue(trasher.paths.isEmpty)

        // ファイル操作の間は新しいスキャンを始めない
        XCTAssertTrue(coordinator.beginFileOperation(on: second))
        XCTAssertThrowsError(try coordinator.start(scope: ScanScope(rootPath: "/Users/me/work", kind: .folder)!)) { error in
            XCTAssertEqual(error as? ScanCoordinatorError, .fileOperationInProgress)
        }
        XCTAssertEqual(service.candidate(for: id(second, "/Users/me/work/big.mov"), in: second), .failure(.operationInProgress))
        coordinator.endFileOperation()
    }

    func testAbortsWhenAncestorReplacedByAnotherDirectory() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/sub/a.bin"), in: session).get()
        fs.replace("/Users/me/work/sub", with: FileMetadata(kind: .directory, identity: FileIdentity(device: 1, inode: 4_242)))
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("別のフォルダへの置換を検知して中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
    }

    func testAbortsWhenContentChanged() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        var metadata = try fs.metadata(atPath: "/Users/me/work/big.mov").get()
        metadata.logicalSize = 99_999
        fs.replace("/Users/me/work/big.mov", with: metadata)
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("内容の更新を検知して中止する")
        }
    }

    func testTrasherFailureIsReturnedAsIs() async throws {
        trasher.error = TrashFailure.unsupported
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        XCTAssertEqual(service.moveToTrash(candidate, in: session), .failure(.unsupported))
        XCTAssertFalse(coordinator.isFileOperationInProgress, "失敗後もゲートを解放する")
    }

    func testPackageAboveRootIsRecheckedBeforeMove() async throws {
        let session = try await completedSession(root: "/Users/me/work/sub")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/sub/a.bin"), in: session).get()
        // 確認の後で祖先がパッケージとして扱われるようになった（判定不能を含む）
        var work = try fs.metadata(atPath: "/Users/me/work").get()
        work.isPackageUnknown = true
        fs.replace("/Users/me/work", with: work)
        XCTAssertEqual(service.moveToTrash(candidate, in: session), .failure(.blocked(.insidePackage)))
    }

    func testRejectsWhileScanning() async throws {
        let gate = Gate()
        fs.onList = { @Sendable _ in gate.wait() }
        let session = try coordinator.start(scope: ScanScope(rootPath: "/Users/me/work", kind: .folder)!)
        XCTAssertEqual(service().candidate(for: ItemID(0), in: session), .failure(.scanNotFinished))
        session.cancel()
        XCTAssertEqual(service().candidate(for: ItemID(0), in: session), .failure(.scanNotFinished), "キャンセル待ちの間も禁止")
        gate.open()
        _ = await session.waitUntilFinished()
    }

    func testAbortsWhenFileReplacedAfterConfirmation() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        fs.replace("/Users/me/work/big.mov", with: FileMetadata(
            kind: .file, logicalSize: 1, allocatedSize: 1, identity: FileIdentity(device: 1, inode: 12_345)
        ))
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("置換を検知して中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
        XCTAssertFalse(session.result.isStale)
    }

    func testAbortsWhenFileVanished() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        fs.remove("/Users/me/work/big.mov")
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("消失を検知して中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
    }

    func testAbortsWhenParentBecomesSymlink() async throws {
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/sub/a.bin"), in: session).get()
        fs.replace("/Users/me/work/sub", with: FileMetadata(kind: .symbolicLink, identity: FileIdentity(device: 1, inode: 7)))
        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("親のリンク化を検知して中止する")
        }
        XCTAssertTrue(trasher.paths.isEmpty)
    }

    func testSystemRefusalDoesNotFallBack() async throws {
        struct Refused: Error {}
        trasher.error = Refused()
        let session = try await completedSession(root: "/Users/me/work")
        let service = service()
        let candidate = try service.candidate(for: id(session, "/Users/me/work/big.mov"), in: session).get()
        guard case .failure(.systemRefused) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("拒否をそのまま返す")
        }
        XCTAssertFalse(session.result.isStale)
        XCTAssertFalse(service.isMoved(candidate.itemID, in: session))
        XCTAssertTrue(fs.metadata(atPath: "/Users/me/work/big.mov").isSuccess, "完全削除しない")
    }

    func testScopeResolverTreatsRootAsStartupDisk() {
        let scope = ScopeResolver.scope(forPath: "/", isVolume: true, provider: fs, resolve: { $0 })!
        XCTAssertEqual(scope.kind, .startupDisk)
        XCTAssertEqual(scope.excludedPaths, ScopeResolver.startupDiskExclusions)
        let folder = ScopeResolver.scope(forPath: "/tmp/x", isVolume: false, provider: fs, resolve: { _ in "/private/tmp/x" })!
        XCTAssertEqual(folder.rootPath, "/private/tmp/x")
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertNil(ScopeResolver.scope(forPath: "/missing", isVolume: false, provider: fs, resolve: { _ in nil }))
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
