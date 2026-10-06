import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ScanCoordinatorError: Error, Equatable, Sendable {
    /// 実行中（キャンセル待ちを含む）のスキャンがある
    case scanInProgress
    /// ゴミ箱移動などのファイル操作を実行中
    case fileOperationInProgress
}

/// アプリ全体で実行中のスキャンを1件に制限し、各スキャンのスレッド構成を組み立てる。
/// ファイル操作とスキャンが同時に走らないよう、両者の排他もここで管理する。
///
/// ```text
/// 列挙スレッド ──(上限付きキュー)──> 保存スレッド ──> ScanStore
///                                                   │
///                         進捗タイマー（既定 250 ms）──> ScanSession.makeUpdates()
/// ```
public final class ScanCoordinator: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// UI 向け進捗の通知間隔
        public var notifyInterval: TimeInterval = 0.25
        /// 保存用キューに溜められるバッチ数
        public var queueCapacity: Int = 16
        public var batchSize: Int = 1024
        public var provisionalFileLimit: Int = 10_000

        public init() {}
    }

    private let provider: any FileSystemProvider
    private let configuration: Configuration
    private let lock = NSLock()
    private var currentSession: ScanSession?
    private var fileOperationInProgress = false

    public init(provider: any FileSystemProvider = POSIXFileSystem(), configuration: Configuration = Configuration()) {
        self.provider = provider
        self.configuration = configuration
    }

    public var current: ScanSession? {
        lock.lock()
        defer { lock.unlock() }
        return currentSession
    }

    public var isFileOperationInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileOperationInProgress
    }

    /// `session` が現在の結果で、走査が終わっており、他の操作がない場合に限り、ファイル操作を始める。
    /// 成功したら必ず `endFileOperation()` を呼ぶ。操作中は新しいスキャンを始めない。
    public func beginFileOperation(on session: ScanSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fileOperationInProgress,
              currentSession === session,
              session.currentState.isTerminal else { return false }
        fileOperationInProgress = true
        return true
    }

    public func endFileOperation() {
        lock.lock()
        fileOperationInProgress = false
        lock.unlock()
    }

    /// `session` が現在の結果で、走査が終わっているか。
    public func isCurrentAndFinished(_ session: ScanSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentSession === session && session.currentState.isTerminal
    }

    /// 新しいスキャンを始める。前のスキャンが終端状態でない、またはファイル操作中なら失敗する。
    /// 対象を変える場合は、前のセッションを `cancel()` して `waitUntilFinished()` を待ってから呼ぶ。
    public func start(scope: ScanScope) throws -> ScanSession {
        lock.lock()
        if fileOperationInProgress {
            lock.unlock()
            throw ScanCoordinatorError.fileOperationInProgress
        }
        if let currentSession, !currentSession.currentState.isTerminal {
            lock.unlock()
            throw ScanCoordinatorError.scanInProgress
        }
        let session = ScanSession(scope: scope, provisionalFileLimit: configuration.provisionalFileLimit)
        currentSession = session
        lock.unlock()

        launch(session)
        return session
    }

    private func launch(_ session: ScanSession) {
        let queue = BoundedQueue<[ScanRecord]>(capacity: configuration.queueCapacity)
        let scanner = FileSystemScanner(scope: session.scope, provider: provider, batchSize: configuration.batchSize)
        let termination = TerminationBox()

        let ticker = ProgressTicker(interval: configuration.notifyInterval) { session.publish() }
        // 強制中止で保存スレッドより先に確定した場合も、タイマーを止める
        session.onFinish { ticker.cancel() }
        session.publish(force: true)

        let ingest = Thread {
            while let batch = queue.take() {
                session.store.apply(batch)
                // 保存が続く間も他のスレッドに実行の機会を譲る（ロックが待ち手へ渡る保証はない。
                // 主な対策は、進捗を別ロックで読めることと、重い並べ替えをロックの外で行うこと）
                sched_yield()
            }
            // 未反映のバッチと集計を確定してから最終イベントを通知する
            ticker.cancel()
            session.finish(termination: termination.value ?? .cancelled)
        }
        ingest.name = "DiskUsage.ingest"
        ingest.qualityOfService = .userInitiated

        let enumerate = Thread {
            let result = scanner.run(isCancelled: { session.isCancelRequested }) { batch in
                queue.put(batch)
            }
            termination.value = result
            queue.close()
        }
        enumerate.name = "DiskUsage.scanner"
        enumerate.qualityOfService = .userInitiated

        ingest.start()
        enumerate.start()
    }
}

/// 一定間隔で進捗を通知するタイマー。
private final class ProgressTicker: @unchecked Sendable {
    private let timer: any DispatchSourceTimer

    init(interval: TimeInterval, handler: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "DiskUsage.progress", qos: .utility))
        let milliseconds = DispatchTimeInterval.milliseconds(max(1, Int(interval * 1000)))
        timer.schedule(deadline: .now() + milliseconds, repeating: milliseconds)
        timer.setEventHandler(handler: handler)
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }
}

/// 列挙スレッドから保存スレッドへ終わり方を渡す。
private final class TerminationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScanTermination?

    var value: ScanTermination? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
