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
/// `filesPerLeaf` 個のファイルを置く。既定値で 10,000,000 ファイル・111,111 フォルダ。
struct SyntheticFileSystem: FileSystemProvider {
    let depth: Int
    let fanout: Int
    let filesPerLeaf: Int

    init(depth: Int = 5, fanout: Int = 10, filesPerLeaf: Int = 100) {
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

/// 性能の合格基準（REQUIREMENTS.md §8、2026-10-07 決定）を検査するベンチマーク。通常のテストでは実行しない。
///
/// - 合成した 1000 万件: ピークメモリ 2 GB 以内、走査中と完了後の問い合わせ 100 ms 以内。
///   実行: `MDU_BENCHMARK=1 swift test -c release --filter BenchmarkTests`
///   （`MDU_BENCHMARK_DEPTH=4` で 100 万件に減らせる）
/// - 実ディスクの走査速度: 1000 万件を 5 分以内に走査できる速さ（毎秒 33,334 件）以上。
///   実行: `MDU_DISK_BENCHMARK_PATH=/ swift test -c release --filter BenchmarkTests/testRealDiskThroughput`
///   （キャッシュを捨てた状態で測るため、直前に `sudo purge` を実行する）
final class BenchmarkTests: XCTestCase {
    /// ピークメモリの上限（バイト）
    static let peakMemoryLimit = 2_000_000_000
    /// UI の問い合わせの応答時間の上限
    static let queryLatencyLimit: Duration = .milliseconds(100)
    /// 1000 万件を 300 秒で走査する速さ（件/秒）
    static let throughputLimit = 10_000_000.0 / 300

    func testTenMillionFileScan() async throws {
        guard ProcessInfo.processInfo.environment["MDU_BENCHMARK"] == "1" else {
            throw XCTSkip("MDU_BENCHMARK=1 のときだけ実行する")
        }
        let depth = ProcessInfo.processInfo.environment["MDU_BENCHMARK_DEPTH"].flatMap(Int.init) ?? 5
        let fs = SyntheticFileSystem(depth: depth)
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
                    _ = store.item(root)
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
        _ = store.largestFiles(offset: fs.expectedFiles / 2, limit: 200)
        let pageDuration = clock.now - pageStart

        let peak = Self.peakResidentBytes()
        XCTAssertEqual(largest.items.count, 200)
        print("""
        [benchmark] files=\(result.counts.files) directories=\(result.counts.directories) items=\(store.itemCount)
        [benchmark] scan=\(scanDuration) updates=\(updates) maxGapBetweenUpdates=\(maxGap)
        [benchmark] readerQueries=\(readerLatency.count) maxReaderLatency=\(readerLatency.maximum)
        [benchmark] largestFilesQueryAfterFinish=\(largestDuration) deepPage=\(pageDuration) leafChildrenQuery=\(childDuration)
        [benchmark] nodeStride=\(ScanStore.nodeStride) bytes peakRSS=\(peak / 1_000_000) MB
        """)
        XCTAssertLessThanOrEqual(peak, Self.peakMemoryLimit, "ピークメモリは 2 GB 以内")
        XCTAssertLessThanOrEqual(readerLatency.maximum, Self.queryLatencyLimit, "走査中の問い合わせは 100 ms 以内")
        for (name, duration) in [("大きなファイル", largestDuration), ("深いページ", pageDuration), ("直下一覧", childDuration)] {
            XCTAssertLessThanOrEqual(duration, Self.queryLatencyLimit, "完了後の\(name)の問い合わせは 100 ms 以内")
        }
    }

    /// 実ディスクを走査し、1000 万件換算で 5 分以内に終わる速さかを測る。
    ///
    /// 対象が大きくても CI の時間内に収まるよう、`MDU_DISK_BENCHMARK_SECONDS`（既定 120 秒）で打ち切り、
    /// それまでの件数から速さを求める。
    func testRealDiskThroughput() async throws {
        guard let path = ProcessInfo.processInfo.environment["MDU_DISK_BENCHMARK_PATH"] else {
            throw XCTSkip("MDU_DISK_BENCHMARK_PATH を指定したときだけ実行する")
        }
        let limit = ProcessInfo.processInfo.environment["MDU_DISK_BENCHMARK_SECONDS"].flatMap(Double.init) ?? 120
        let scope = try XCTUnwrap(ScopeResolver.scope(forPath: path, isVolume: false))
        let coordinator = ScanCoordinator()
        let clock = ContinuousClock()
        let start = clock.now
        let session = try coordinator.start(scope: scope)
        let deadline = Task {
            try await Task.sleep(for: .seconds(limit))
            session.cancel()
        }
        let result = await session.waitUntilFinished()
        deadline.cancel()
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = Double(result.counts.enumeratedItems) / max(seconds, 0.001)
        print("""
        [benchmark] disk=\(path) state=\(result.state) items=\(result.counts.enumeratedItems) problems=\(result.counts.problemItems)
        [benchmark] diskScan=\(elapsed) rate=\(Int(rate)) items/s estimatedFor10M=\(Int(10_000_000 / max(rate, 1))) s
        [benchmark] peakRSS=\(Self.peakResidentBytes() / 1_000_000) MB
        """)
        XCTAssertGreaterThan(result.counts.enumeratedItems, 100_000, "速さを測るのに十分な件数を走査する")
        XCTAssertGreaterThanOrEqual(rate, Self.throughputLimit, "1000 万件を 5 分以内に走査できる速さ")
    }

    /// 1つのフォルダに 200,000 件のファイルがある場合の、直下一覧の並べ替えと保存処理への影響を測る。
    func testHugeFlatDirectory() async throws {
        guard ProcessInfo.processInfo.environment["MDU_BENCHMARK"] == "1" else {
            throw XCTSkip("MDU_BENCHMARK=1 のときだけ実行する")
        }
        let fs = SyntheticFileSystem(depth: 0, fanout: 0, filesPerLeaf: 200_000)
        let coordinator = ScanCoordinator(provider: fs)
        let clock = ContinuousClock()
        let session = try coordinator.start(scope: ScanScope(rootPath: "/bench", kind: .folder)!)

        // 走査中に直下一覧を繰り返し問い合わせ、ほかの問い合わせ（件数の取得）が待たされないかを見る
        let statsLatency = LatencyRecorder()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            defer { done.signal() }
            let store = session.store
            while !session.currentState.isTerminal {
                if let root = store.rootID {
                    _ = store.children(of: root, offset: 0, limit: 200)
                }
            }
        }
        let statsReader = Thread {
            let store = session.store
            while !session.currentState.isTerminal {
                let begin = ContinuousClock.now
                _ = store.item(ItemID(0))
                statsLatency.record(ContinuousClock.now - begin)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        reader.start()
        statsReader.start()
        let result = await session.waitUntilFinished()
        blockingWait(done)
        XCTAssertEqual(result.counts.files, 200_000)

        let begin = clock.now
        let page = session.store.children(of: session.store.rootID!, offset: 100_000, limit: 200)
        let firstSort = clock.now - begin
        let cachedBegin = clock.now
        _ = session.store.children(of: session.store.rootID!, offset: 0, limit: 200)
        let cached = clock.now - cachedBegin
        XCTAssertEqual(page.items.count, 200)
        print("""
        [benchmark] flatFiles=\(result.counts.files) childrenSortAfterFinish=\(firstSort) cachedChildrenQuery=\(cached)
        [benchmark] maxItemQueryLatencyWhileSorting=\(statsLatency.maximum) samples=\(statsLatency.count)
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
