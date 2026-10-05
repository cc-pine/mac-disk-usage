import XCTest
@testable import DiskUsageCore

final class ScanCoordinatorTests: XCTestCase {
    private func makeTree() -> MockFileSystem {
        let fs = MockFileSystem()
        fs.dir("/data")
        for d in 0..<20 {
            fs.dir("/data/d\(d)")
            for f in 0..<20 {
                fs.file("/data/d\(d)/f\(f)", allocated: 100)
            }
        }
        return fs
    }

    private func configuration() -> ScanCoordinator.Configuration {
        var configuration = ScanCoordinator.Configuration()
        configuration.notifyInterval = 0.02
        configuration.batchSize = 7
        configuration.queueCapacity = 2
        return configuration
    }

    func testCompletesAndPublishesTerminalEventLast() async throws {
        let coordinator = ScanCoordinator(provider: makeTree(), configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)

        var events: [ScanProgress] = []
        for await progress in session.makeUpdates() {
            events.append(progress)
        }
        let result = await session.waitUntilFinished()

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.filter { $0.state.isTerminal }.count, 1, "終端イベントは一度だけ")
        XCTAssertTrue(events.allSatisfy { $0.scanID == session.scanID })
        XCTAssertEqual(result.counts.files, 400)
        XCTAssertEqual(session.store.item(session.store.rootID!)!.sizeSummary.knownAllocatedBytes, 40_000)
        XCTAssertNotNil(result.finishedAt)
        XCTAssertEqual(events.last?.counts.files, 400, "最終イベントの前に全バッチを保存する")
    }

    func testCompletedWithErrorsWhenSomethingUnreadable() async throws {
        let fs = makeTree()
        fs.denyListing("/data/d3")
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)
        let result = await session.waitUntilFinished()
        XCTAssertEqual(result.state, .completedWithErrors)
        XCTAssertEqual(result.counts.problemItems, 1)
    }

    func testRootFailureIsFailed() async throws {
        let coordinator = ScanCoordinator(provider: MockFileSystem(), configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/nope", kind: .folder)!)
        let result = await session.waitUntilFinished()
        XCTAssertEqual(result.state, .failed)
        XCTAssertNotNil(result.failureDescription)
    }

    func testOnlyOneScanAtATimeAndRescanAfterCancel() async throws {
        let fs = makeTree()
        let gate = Gate()
        let entered = DispatchSemaphore(value: 0)
        fs.onList = { @Sendable _ in
            entered.signal()
            gate.wait()
        }
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration())
        let scope = ScanScope(rootPath: "/data", kind: .folder)!
        let first = try coordinator.start(scope: scope)
        // OS 呼び出しの最中にキャンセルする状況を作る
        blockingWait(entered)

        XCTAssertThrowsError(try coordinator.start(scope: scope)) { error in
            XCTAssertEqual(error as? ScanCoordinatorError, .scanInProgress)
        }

        first.cancel()
        XCTAssertEqual(first.currentState, .cancelling, "キャンセル要求はすぐ状態に反映する")
        XCTAssertThrowsError(try coordinator.start(scope: scope), "キャンセル待ちの間も新しいスキャンは始めない")

        gate.open()
        let firstResult = await first.waitUntilFinished()
        XCTAssertEqual(firstResult.state, .cancelled)
        XCTAssertTrue(first.store.item(first.store.rootID!)!.sizeSummary.hasUnvisitedDescendants)

        let second = try coordinator.start(scope: scope)
        XCTAssertNotEqual(second.scanID, first.scanID)
        let secondResult = await second.waitUntilFinished()
        XCTAssertEqual(secondResult.state, .completed)
        XCTAssertEqual(first.currentState, .cancelled, "旧スキャンの状態は変わらない")
        XCTAssertTrue(coordinator.current === second)
    }

    func testEachSubscriberGetsTerminalEventAndLateSubscriberEndsImmediately() async throws {
        let coordinator = ScanCoordinator(provider: makeTree(), configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)
        let first = session.makeUpdates()
        let second = session.makeUpdates()
        async let lastOfFirst = first.reduce(nil as ScanProgress?) { $1 }
        async let lastOfSecond = second.reduce(nil as ScanProgress?) { $1 }
        let (a, b) = await (lastOfFirst, lastOfSecond)
        XCTAssertEqual(a?.state, .completed)
        XCTAssertEqual(b?.state, .completed)

        var late: [ScanProgress] = []
        for await progress in session.makeUpdates() {
            late.append(progress)
        }
        XCTAssertEqual(late.map(\.state), [.completed])
    }

    /// OS 呼び出しが戻らない場合でも、猶予を過ぎたら中止を確定し、次のスキャンを始められる。
    func testStuckScanIsAbandonedAfterGracePeriod() async throws {
        let fs = makeTree()
        let gate = Gate()
        let entered = DispatchSemaphore(value: 0)
        fs.onList = { @Sendable path in
            if path == "/data" {
                entered.signal()
                gate.wait()
            }
        }
        var configuration = configuration()
        configuration.cancelGracePeriod = 0.2
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration)
        let scope = ScanScope(rootPath: "/data", kind: .folder)!
        let stuck = try coordinator.start(scope: scope)
        blockingWait(entered)
        stuck.cancel()

        let result = await stuck.waitUntilFinished()
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertNotNil(result.failureDescription, "停止を確認できなかったことを伝える")

        fs.onList = nil
        let next = try coordinator.start(scope: scope)
        gate.open()
        let nextResult = await next.waitUntilFinished()
        XCTAssertEqual(nextResult.state, .completed)
        XCTAssertEqual(stuck.currentState, .cancelled, "後から戻った旧スキャンの状態は変わらない")
    }

    func testCancelAfterFinishDoesNotChangeTerminalState() async throws {
        let coordinator = ScanCoordinator(provider: makeTree(), configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)
        _ = await session.waitUntilFinished()
        session.cancel()
        XCTAssertEqual(session.currentState, .completed)
    }

    func testMarkStaleKeepsState() async throws {
        let coordinator = ScanCoordinator(provider: makeTree(), configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)
        _ = await session.waitUntilFinished()
        session.markStale()
        XCTAssertTrue(session.result.isStale)
        XCTAssertEqual(session.result.state, .completed)
    }

    func testBoundedQueueBlocksProducerWithoutDropping() {
        let queue = BoundedQueue<Int>(capacity: 2)
        let produced = expectation(description: "produced")
        DispatchQueue.global().async {
            for i in 0..<100 {
                queue.put(i)
            }
            queue.close()
            produced.fulfill()
        }
        var received: [Int] = []
        while let value = queue.take() {
            XCTAssertLessThanOrEqual(queue.count, 2)
            received.append(value)
        }
        wait(for: [produced], timeout: 5)
        XCTAssertEqual(received, Array(0..<100))
    }
}

/// 開くまで待たせる単純なゲート。
final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

/// async のテストからセマフォを待つための同期関数（Darwin では async 文脈から直接 wait できない）。
func blockingWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}
