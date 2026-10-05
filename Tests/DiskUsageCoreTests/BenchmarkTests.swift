import Foundation
import XCTest
@testable import DiskUsageCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 決まった形の大きなツリーをその場で生成する模擬ファイルシステム。
///
/// 深さ `depth` まで各フォルダに `fanout` 個のサブフォルダを持ち、最下層のフォルダに
/// `filesPerLeaf` 個のファイルを置く。既定値で 1,000,000 ファイル・11,111 フォルダ。
struct SyntheticFileSystem: FileSystemProvider {
    let depth: Int
    let fanout: Int
    let filesPerLeaf: Int

    init(depth: Int = 4, fanout: Int = 10, filesPerLeaf: Int = 100) {
        self.depth = depth
        self.fanout = fanout
        self.filesPerLeaf = filesPerLeaf
    }

    var expectedFiles: Int {
        var leaves = 1
        for _ in 0..<depth { leaves *= fanout }
        return leaves * filesPerLeaf
    }

    func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError> {
        .success(FileMetadata(kind: .directory, identity: identity(path)))
    }

    func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError> {
        let level = path == "/bench" ? 0 : PathUtilities.components(of: path).count - 1
        var entries: [DirectoryEntry] = []
        if level < depth {
            entries.reserveCapacity(fanout)
            for i in 0..<fanout {
                let name = "d\(i)"
                entries.append(DirectoryEntry(name: name, metadata: .success(FileMetadata(
                    kind: .directory, identity: identity(path + "/" + name)
                ))))
            }
        } else {
            entries.reserveCapacity(filesPerLeaf)
            // hashValue はプロセスごとに変わるため、毎回同じ値になる FNV を種にする
            var seed = identity(path).inode
            for i in 0..<filesPerLeaf {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let logical = Int64(seed >> 44)  // 0〜1 MB 程度
                let allocated = (logical + 4095) / 4096 * 4096
                entries.append(DirectoryEntry(name: "file\(i).bin", metadata: .success(FileMetadata(
                    kind: .file, logicalSize: logical, allocatedSize: allocated,
                    modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
                    identity: FileIdentity(device: 1, inode: seed)
                ))))
            }
        }
        return .success(DirectoryListing(entries: entries))
    }

    private func identity(_ path: String) -> FileIdentity {
        // FNV-1a。ディレクトリの重複検知に使うだけなので衝突は実質無視できる
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return FileIdentity(device: 1, inode: hash)
    }
}

/// 100万件規模の走査と問い合わせを計測する。通常のテストでは実行しない。
///
/// 実行: `MDU_BENCHMARK=1 swift test -c release --filter BenchmarkTests`
final class BenchmarkTests: XCTestCase {
    func testMillionFileScan() async throws {
        guard ProcessInfo.processInfo.environment["MDU_BENCHMARK"] == "1" else {
            throw XCTSkip("MDU_BENCHMARK=1 のときだけ実行する")
        }
        let fs = SyntheticFileSystem()
        let coordinator = ScanCoordinator(provider: fs)
        let clock = ContinuousClock()

        let start = clock.now
        let session = try coordinator.start(scope: ScanScope(rootPath: "/bench", kind: .folder)!)

        // 走査中に UI と同じ問い合わせを繰り返し、待たされた最大時間を測る
        let readerLatency = LatencyRecorder()
        let readerDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            defer { readerDone.signal() }
            let store = session.store
            while !session.currentState.isTerminal {
                let begin = ContinuousClock.now
                if let root = store.rootID {
                    _ = store.children(of: root, offset: 0, limit: 200)
                    _ = store.largestFiles(offset: 0, limit: 200)
                }
                readerLatency.record(ContinuousClock.now - begin)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        reader.start()

        var maxGap: Duration = .zero
        var last = clock.now
        var updates = 0
        for await _ in session.makeUpdates() {
            let now = clock.now
            maxGap = max(maxGap, now - last)
            last = now
            updates += 1
        }
        let result = await session.waitUntilFinished()
        let scanDuration = clock.now - start
        blockingWait(readerDone)

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.counts.files, fs.expectedFiles)

        let store = session.store
        let queryStart = clock.now
        let largest = store.largestFiles(offset: 0, limit: 200)
        let largestDuration = clock.now - queryStart

        let childStart = clock.now
        var leaf = store.rootID!
        while let next = store.children(of: leaf, offset: 0, limit: 1).items.first, next.kind == .directory {
            leaf = next.id
        }
        _ = store.children(of: leaf, offset: 0, limit: 200)
        let childDuration = clock.now - childStart

        let pageStart = clock.now
        _ = store.largestFiles(offset: 500_000, limit: 200)
        let pageDuration = clock.now - pageStart

        XCTAssertEqual(largest.items.count, 200)
        print("""
        [benchmark] files=\(result.counts.files) directories=\(result.counts.directories) items=\(store.itemCount)
        [benchmark] scan=\(scanDuration) updates=\(updates) maxGapBetweenUpdates=\(maxGap)
        [benchmark] readerQueries=\(readerLatency.count) maxReaderLatency=\(readerLatency.maximum)
        [benchmark] largestFilesQueryAfterFinish=\(largestDuration) deepPage=\(pageDuration) leafChildrenQuery=\(childDuration)
        [benchmark] nodeStride=\(ScanStore.nodeStride) bytes peakRSS=\(Self.peakResidentBytes() / 1_000_000) MB
        """)
    }

    final class LatencyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedMaximum: Duration = .zero
        private var storedCount = 0

        var maximum: Duration {
            lock.lock()
            defer { lock.unlock() }
            return storedMaximum
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedCount
        }

        func record(_ duration: Duration) {
            lock.lock()
            storedMaximum = max(storedMaximum, duration)
            storedCount += 1
            lock.unlock()
        }
    }

    static func peakResidentBytes() -> Int {
        var usage = rusage()
        #if canImport(Darwin)
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
        #else
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        return Int(usage.ru_maxrss) * 1024
        #endif
    }
}
