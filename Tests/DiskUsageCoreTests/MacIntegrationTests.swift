#if os(macOS)
import Foundation
import XCTest
@testable import DiskUsageCore

/// 実際の macOS 上で、起動ディスクの範囲・パッケージ判定・ゴミ箱移動を確かめる。
///
/// ホームフォルダに一時フォルダを作って実ファイルをゴミ箱へ移すため、既定では実行しない。
/// 実行: `MDU_INTEGRATION=1 swift test --filter MacIntegrationTests`（CI の macOS ジョブで有効）
final class MacIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MDU_INTEGRATION"] == "1" else {
            throw XCTSkip("MDU_INTEGRATION=1 のときだけ実行する")
        }
    }

    /// 起動ディスクでは System と Data の両デバイスを許可し、firmlink 経由の /Users を範囲内に含める。
    func testStartupDiskScopeIncludesDataVolume() throws {
        let fs = POSIXFileSystem()
        let scope = ScopeResolver.startupDisk(provider: fs)
        XCTAssertEqual(scope.kind, .startupDisk)
        let root = try XCTUnwrap(try fs.metadata(atPath: "/").get().identity)
        let users = try XCTUnwrap(try fs.metadata(atPath: "/Users").get().identity)
        let data = try XCTUnwrap(try fs.metadata(atPath: ScopeResolver.dataVolumePath).get().identity)
        XCTAssertTrue(scope.allowedDevices.contains(root.device))
        XCTAssertTrue(scope.allowedDevices.contains(data.device))
        XCTAssertTrue(scope.allowedDevices.contains(users.device), "/Users（Data 側）を別ボリュームとして除外しない")
        XCTAssertEqual(scope.excludedPaths, ScopeResolver.startupDiskExclusions)
    }

    /// ルート直下と /System だけを列挙し、別名経路・他のマウント先の除外と /Users の包含を確かめる。
    func testStartupDiskTopLevelExclusions() throws {
        let fs = ShallowFileSystem(base: POSIXFileSystem(), listable: ["/", "/System"])
        let scope = ScopeResolver.startupDisk(provider: fs)
        let store = ScanStore(rootPath: "/")
        let termination = FileSystemScanner(scope: scope, provider: fs).run(isCancelled: { false }) { store.apply($0) }
        store.finalize()
        XCTAssertEqual(termination, .finished)

        let top = store.children(of: store.rootID!).items
        func child(_ name: String, in items: [ScanItem]) -> ScanItem? { items.first { $0.name == name } }
        XCTAssertNil(child("Users", in: top)?.exclusionReason)
        XCTAssertEqual(child("Volumes", in: top)?.exclusionReason, .scopeRule)
        XCTAssertEqual(child("dev", in: top)?.exclusionReason, .scopeRule)
        let system = try XCTUnwrap(child("System", in: top))
        let systemChildren = store.children(of: system.id).items
        XCTAssertEqual(child("Volumes", in: systemChildren)?.exclusionReason, .scopeRule, "/System/Volumes を二重に数えない")
    }

    func testAppBundleIsDetectedAsPackage() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mdu-pkg-\(UUID().uuidString)")
        let app = base.appendingPathComponent("Sample.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let metadata = try POSIXFileSystem().metadata(atPath: base.appendingPathComponent("Sample.app").path).get()
        XCTAssertTrue(metadata.isPackage)
        XCTAssertFalse(try POSIXFileSystem().metadata(atPath: base.path).get().isPackage)
    }

    /// 専用の一時フォルダの通常ファイルだけを、実際にゴミ箱へ移す。
    func testMovesTemporaryFileToTrash() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("mdu-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("disposable.bin")
        try Data(repeating: 7, count: 50_000).write(to: file)
        var trashedPath: String?
        defer {
            if let trashedPath {
                try? FileManager.default.removeItem(atPath: trashedPath)
            }
            try? FileManager.default.removeItem(at: base)
        }

        let coordinator = ScanCoordinator()
        let scope = try XCTUnwrap(ScopeResolver.scope(forPath: base.path, isVolume: false))
        let session = try coordinator.start(scope: scope)
        let result = await session.waitUntilFinished()
        XCTAssertEqual(result.state, .completed)

        let fileItem = try XCTUnwrap(session.store.children(of: session.store.rootID!).items.first { $0.name == "disposable.bin" })
        let service = ItemActionService(coordinator: coordinator)
        let candidate = try service.candidate(for: fileItem.id, in: session).get()
        let outcome = try service.moveToTrash(candidate, in: session).get()
        trashedPath = outcome.trashedPath

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "元の場所から移動している")
        let moved = try XCTUnwrap(outcome.trashedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved), "ゴミ箱に存在する（完全削除していない）")
        XCTAssertEqual(try POSIXFileSystem().metadata(atPath: moved).get().identity, candidate.identity)
        XCTAssertTrue(session.result.isStale)
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
