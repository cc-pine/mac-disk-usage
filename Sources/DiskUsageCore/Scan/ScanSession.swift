import Foundation

/// 結果全体の情報。状態と別に「古い結果か」を持つ。
public struct ScanResult: Equatable, Sendable {
    public let scanID: ScanID
    public let scope: ScanScope
    public let state: ScanState
    public let startedAt: Date
    public let finishedAt: Date?
    public let revision: Int
    public let counts: ScanCounts
    /// ゴミ箱移動などで、現在のファイルシステムと一致しない可能性がある
    public let isStale: Bool
    /// ルートを列挙できなかった場合などの短い説明
    public let failureDescription: String?
}

/// 1回のスキャン。ライフサイクルと終端状態の確定を一元化する。
///
/// 列挙は専用スレッド、保存は別スレッドで行い、間を上限付きキューでつなぐ。
/// UI 向けの進捗は一定間隔でまとめ、最新の値だけを `updates` に流す。
public final class ScanSession: @unchecked Sendable {
    public let scanID = ScanID()
    public let scope: ScanScope
    public let store: ScanStore

    private let lock = NSLock()
    private var state: ScanState = .scanning
    private var cancelRequested = false
    private var isStale = false
    private var failureDescription: String?
    private let startedAt = Date()
    private let startedUptime = ProcessInfo.processInfo.systemUptime
    private var finishedAt: Date?
    private var finishedUptime: TimeInterval?
    private var lastPublished: (revision: Int, state: ScanState, isStale: Bool)?
    private var continuation: AsyncStream<ScanProgress>.Continuation?
    private var finishWaiters: [CheckedContinuation<ScanResult, Never>] = []

    /// 最新の進捗だけを保持するストリーム。終端イベントの後に終わる。
    public let updates: AsyncStream<ScanProgress>

    init(scope: ScanScope, provisionalFileLimit: Int) {
        self.scope = scope
        store = ScanStore(rootPath: scope.rootPath, provisionalFileLimit: provisionalFileLimit)
        var continuation: AsyncStream<ScanProgress>.Continuation?
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.continuation = continuation
    }

    // MARK: - 公開状態

    public var currentState: ScanState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var isCancelRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    public var result: ScanResult {
        lock.lock()
        defer { lock.unlock() }
        return resultLocked()
    }

    public var progress: ScanProgress {
        lock.lock()
        defer { lock.unlock() }
        return progressLocked()
    }

    /// キャンセルを要求する。状態はすぐ `cancelling` になり、列挙が止まってから `cancelled` に確定する。
    public func cancel() {
        lock.lock()
        guard state == .scanning else {
            lock.unlock()
            return
        }
        cancelRequested = true
        state = .cancelling
        lock.unlock()
        publish(force: true)
    }

    /// ゴミ箱移動などの後で、結果が古いことを記録する。走査完了という事実は変えない。
    public func markStale() {
        lock.lock()
        isStale = true
        lock.unlock()
        publish(force: true)
    }

    /// 終端状態が確定するまで待つ。
    public func waitUntilFinished() async -> ScanResult {
        await withCheckedContinuation { waiter in
            lock.lock()
            if state.isTerminal {
                let result = resultLocked()
                lock.unlock()
                waiter.resume(returning: result)
            } else {
                finishWaiters.append(waiter)
                lock.unlock()
            }
        }
    }

    // MARK: - コーディネーターから呼ぶ

    /// 進捗を流す。版・状態が変わっていなければ送らない。
    func publish(force: Bool = false) {
        lock.lock()
        let progress = progressLocked()
        let key = (progress.revision, progress.state, isStale)
        if !force, let last = lastPublished, last == key {
            lock.unlock()
            return
        }
        lastPublished = key
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(progress)
    }

    /// 終端状態を一度だけ確定する。保存と集計の確定後に呼ぶ。
    func finish(termination: ScanTermination) {
        store.finalize()
        // 大きなファイル一覧の全件索引を、終端を通知する前にこのスレッドで作っておく
        store.prepareFileIndex()
        lock.lock()
        guard !state.isTerminal else {
            lock.unlock()
            return
        }
        let next: ScanState
        if cancelRequested {
            next = .cancelled
        } else {
            switch termination {
            case .cancelled:
                next = .cancelled
            case .rootFailed(let error):
                next = .failed
                failureDescription = error.message
            case .finished:
                next = hasMissingInformation() ? .completedWithErrors : .completed
            }
        }
        assert(state.canTransition(to: next), "\(state) → \(next) は許可されていない遷移")
        state = next
        finishedAt = Date()
        finishedUptime = ProcessInfo.processInfo.systemUptime
        let result = resultLocked()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        let continuation = self.continuation
        self.continuation = nil
        lastPublished = (store.currentRevision, state, isStale)
        let progress = progressLocked()
        lock.unlock()

        continuation?.yield(progress)
        continuation?.finish()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    // MARK: - 内部

    private func hasMissingInformation() -> Bool {
        let counts = store.currentCounts
        if counts.problemItems > 0 {
            return true
        }
        guard let rootID = store.rootID, let root = store.item(rootID) else { return true }
        return root.sizeSummary.isIncomplete || root.sizeSummary.isLogicalIncomplete || root.traversalState == .partial
    }

    private func elapsedLocked() -> TimeInterval {
        (finishedUptime ?? ProcessInfo.processInfo.systemUptime) - startedUptime
    }

    private func progressLocked() -> ScanProgress {
        ScanProgress(
            scanID: scanID,
            revision: store.currentRevision,
            state: state,
            counts: store.currentCounts,
            startedAt: startedAt,
            finishedAt: finishedAt,
            elapsed: elapsedLocked()
        )
    }

    private func resultLocked() -> ScanResult {
        ScanResult(
            scanID: scanID,
            scope: scope,
            state: state,
            startedAt: startedAt,
            finishedAt: finishedAt,
            revision: store.currentRevision,
            counts: store.currentCounts,
            isStale: isStale,
            failureDescription: failureDescription
        )
    }
}
