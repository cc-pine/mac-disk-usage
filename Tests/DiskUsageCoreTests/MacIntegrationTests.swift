#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import DiskUsageCore

/// 実際の macOS 上で、起動ディスクの範囲・パッケージ判定・ゴミ箱移動を確かめる。
///
/// ホームフォルダに一時フォルダを作って実ファイルをゴミ箱へ移すため、既定では実行しない。
/// 実行: `MDU_INTEGRATION=1 swift test --filter MacIntegrationTests`（CI の macOS ジョブで有効）
final class MacIntegrationTests: XCTestCase {
    private let fs = POSIXFileSystem()
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MDU_INTEGRATION"] == "1" else {
            throw XCTSkip("MDU_INTEGRATION=1 のときだけ実行する")
        }
    }

    // MARK: - 起動ディスクの範囲

    /// 起動ディスクでは System と Data の両デバイスを許可し、firmlink 経由の /Users を範囲内に含める。
    func testStartupDiskScopeIncludesDataVolume() throws {
        let scope = ScopeResolver.startupDisk(provider: fs)
        XCTAssertEqual(scope.kind, .startupDisk)
        let root = try XCTUnwrap(try fs.metadata(atPath: "/").get().identity)
        let users = try XCTUnwrap(try fs.metadata(atPath: "/Users").get().identity)
        let data = try XCTUnwrap(try fs.metadata(atPath: ScopeResolver.dataVolumePath).get().identity)
        let dataUsers = try XCTUnwrap(try fs.metadata(atPath: ScopeResolver.dataVolumePath + "/Users").get().identity)
        // System と Data のデバイス番号は環境によって同じこともある（GitHub の macOS 15 ランナーでは同じだった）。
        // どちらでも許可する組に含めればよいので、異なることは前提にしない。
        XCTAssertEqual(users, dataUsers, "/Users と /System/Volumes/Data/Users は同じ実体（firmlink）")
        XCTAssertTrue(scope.allowedDevices.contains(root.device))
        XCTAssertTrue(scope.allowedDevices.contains(data.device))
        XCTAssertTrue(scope.allowedDevices.contains(users.device), "/Users（Data 側）を別ボリュームとして除外しない")
        XCTAssertEqual(scope.excludedPaths, ScopeResolver.startupDiskExclusions)
    }

    /// ルート直下と /System だけを列挙し、別名経路・他のマウント先の除外と Data 側フォルダの包含を確かめる。
    func testStartupDiskTopLevelExclusions() throws {
        let shallow = ShallowFileSystem(base: fs, listable: ["/", "/System"])
        let scope = ScopeResolver.startupDisk(provider: shallow)
        let store = ScanStore(rootPath: "/")
        let termination = FileSystemScanner(scope: scope, provider: shallow).run(isCancelled: { false }) { store.apply($0) }
        store.finalize()
        XCTAssertEqual(termination, .finished)

        let rootID = try XCTUnwrap(store.rootID)
        let top = store.children(of: rootID).items
        func child(_ name: String, in items: [ScanItem]) throws -> ScanItem {
            try XCTUnwrap(items.first { $0.name == name }, "\(name) が列挙されていない")
        }
        for name in ["Users", "Applications", "Library", "private"] {
            XCTAssertNil(try child(name, in: top).exclusionReason, "\(name) は範囲内")
        }
        XCTAssertEqual(try child("Volumes", in: top).exclusionReason, .scopeRule)
        XCTAssertEqual(try child("dev", in: top).exclusionReason, .scopeRule)
        let system = try child("System", in: top)
        XCTAssertEqual(try child("Volumes", in: store.children(of: system.id).items).exclusionReason, .scopeRule,
                       "/System/Volumes を二重に数えない")
    }

    func testAppBundleIsDetectedAsPackage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-pkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Sample.app/Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertTrue(try fs.metadata(atPath: base.appendingPathComponent("Sample.app").path).get().isPackage)
        XCTAssertFalse(try fs.metadata(atPath: base.path).get().isPackage)
    }

    // MARK: - ゴミ箱移動

    /// 専用の一時フォルダの通常ファイルだけを、実際にゴミ箱へ移す。
    func testMovesTemporaryFileToTrash() async throws {
        try skipIfTrashIsNotReadable()
        let workspace = try Workspace(home: home)
        defer { workspace.cleanUp() }
        let file = try workspace.makeFile()

        let (coordinator, session) = try await scan(workspace.root)
        let service = ItemActionService(coordinator: coordinator)
        let candidate = try service.candidate(for: try id(of: file, in: session), in: session).get()
        let outcome = try service.moveToTrash(candidate, in: session).get()
        workspace.recordTrashed(outcome.trashedPath, identity: candidate.identity)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "元の場所から移動している")
        let moved = try XCTUnwrap(outcome.trashedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved), "ゴミ箱に存在する（完全削除していない）")
        XCTAssertEqual(try fs.metadata(atPath: moved).get().identity, candidate.identity)
        XCTAssertTrue(session.result.isStale)
    }

    func testRefusesHardLinkedFile() async throws {
        let workspace = try Workspace(home: home)
        defer { workspace.cleanUp() }
        let file = try workspace.makeFile()
        XCTAssertEqual(link(file.path, workspace.root.appendingPathComponent("second-link.bin").path), 0)

        let (coordinator, session) = try await scan(workspace.root)
        let service = ItemActionService(coordinator: coordinator)
        XCTAssertEqual(service.candidate(for: try id(of: file, in: session), in: session), .failure(.multipleHardLinks))
    }

    /// 確認後に親フォルダを、同名ファイルを持つ別フォルダへのリンクに差し替えても、おとりを移動しない。
    func testAbortsWhenParentIsSwappedForSymlink() async throws {
        let workspace = try Workspace(home: home)
        defer { workspace.cleanUp() }
        let sub = workspace.root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = try workspace.makeFile(in: sub)
        let decoyFolder = workspace.root.appendingPathComponent("decoy")
        try FileManager.default.createDirectory(at: decoyFolder, withIntermediateDirectories: true)
        let decoy = decoyFolder.appendingPathComponent(file.lastPathComponent)
        try Data(repeating: 1, count: 10).write(to: decoy)

        let (coordinator, session) = try await scan(workspace.root)
        let service = ItemActionService(coordinator: coordinator)
        let candidate = try service.candidate(for: try id(of: file, in: session), in: session).get()

        try FileManager.default.moveItem(at: sub, to: workspace.root.appendingPathComponent("sub-old"))
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: decoyFolder)

        guard case .failure(.changedSinceScan) = service.moveToTrash(candidate, in: session) else {
            return XCTFail("親フォルダの差し替えを検知して中止する")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path), "おとりのファイルを移動しない")
    }

    func testRefusesFileInsideHomeLibrary() async throws {
        let caches = home.appendingPathComponent("Library/Caches/mdu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caches) }
        let file = caches.appendingPathComponent("cache.bin")
        try Data(repeating: 2, count: 10).write(to: file)

        let (coordinator, session) = try await scan(caches)
        let service = ItemActionService(coordinator: coordinator)
        guard case .failure(.protectedLocation) = service.candidate(for: try id(of: file, in: session), in: session) else {
            return XCTFail("ホームの Library 配下は移動しない")
        }
    }

    // MARK: - 補助

    private func scan(_ root: URL) async throws -> (ScanCoordinator, ScanSession) {
        let coordinator = ScanCoordinator()
        let scope = try XCTUnwrap(ScopeResolver.scope(forPath: root.path, isVolume: false))
        let session = try coordinator.start(scope: scope)
        let result = await session.waitUntilFinished()
        XCTAssertEqual(result.state, .completed)
        return (coordinator, session)
    }

    private func id(of file: URL, in session: ScanSession) throws -> ItemID {
        let store = session.store
        var current = try XCTUnwrap(store.rootID)
        let rootComponents = PathUtilities.components(of: session.scope.rootPath)
        let canonical = try XCTUnwrap(ScopeResolver.canonicalPath(file.path))
        for name in PathUtilities.components(of: canonical).dropFirst(rootComponents.count) {
            current = try XCTUnwrap(store.children(of: current).items.first { $0.name == name }?.id, "\(name) が結果にない")
        }
        return current
    }

    /// Terminal にフルディスクアクセスがない開発機では ~/.Trash を読めず、移動先を確かめられない。
    private func skipIfTrashIsNotReadable() throws {
        let trash = home.appendingPathComponent(".Trash").path
        guard FileManager.default.fileExists(atPath: trash) else { return }
        if case .failure = fs.listDirectory(atPath: trash, expectedIdentity: nil) {
            throw XCTSkip("~/.Trash を読めないため、ゴミ箱移動の結合テストを省略する")
        }
    }
}

/// ホームに作る専用の作業フォルダ。片付けでは、作ったものだけを確かめてから消す。
private final class Workspace {
    let root: URL
    private let home: URL
    private let fileNamePrefix = "mdu-disposable-"
    private var trashed: (path: String, identity: FileIdentity)?

    init(home: URL) throws {
        self.home = home
        root = home.appendingPathComponent("mdu-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeFile(in folder: URL? = nil) throws -> URL {
        let file = (folder ?? root).appendingPathComponent(fileNamePrefix + UUID().uuidString + ".bin")
        try Data(repeating: 7, count: 50_000).write(to: file)
        return file
    }

    func recordTrashed(_ path: String?, identity: FileIdentity) {
        if let path {
            trashed = (path, identity)
        }
    }

    func cleanUp() {
        // ゴミ箱の項目は、~/.Trash 直下・このテストの名前・同じ実体の通常ファイルであるときだけ消す
        if let trashed,
           PathUtilities.isSameOrDescendant(trashed.path, of: home.appendingPathComponent(".Trash").path),
           PathUtilities.lastComponent(of: trashed.path).hasPrefix(fileNamePrefix),
           case .success(let metadata) = POSIXFileSystem().metadata(atPath: trashed.path),
           metadata.kind == .file, metadata.identity == trashed.identity {
            try? FileManager.default.removeItem(atPath: trashed.path)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

/// 指定したフォルダだけを実際に列挙し、それ以外は空として返す（起動ディスク全体を走査しないため）。
private struct ShallowFileSystem: FileSystemProvider {
    let base: POSIXFileSystem
    let listable: Set<String>

    func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError> {
        base.metadata(atPath: path)
    }

    func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError> {
        guard listable.contains(path) else { return .success(DirectoryListing(entries: [])) }
        return base.listDirectory(atPath: path, expectedIdentity: expectedIdentity)
    }

    func prepareScanningThread() {
        base.prepareScanningThread()
    }
}
#endif
