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
        // 購読してから走査を進め、途中の進捗と終端の順序を実際に観察する
        let fs = makeTree()
        let gate = Gate()
        fs.onList = { @Sendable path in
            if path == "/data" { gate.wait() }
        }
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration())
        let session = try coordinator.start(scope: ScanScope(rootPath: "/data", kind: .folder)!)
        let updates = session.makeUpdates()
        gate.open()

        var events: [ScanProgress] = []
        for await progress in updates {
            events.append(progress)
        }
        XCTAssertGreaterThanOrEqual(events.count, 2, "走査中の進捗と終端を受け取る")
        XCTAssertEqual(events.map { $0.revision }, events.map { $0.revision }.sorted(), "版は戻らない")
        XCTAssertEqual(events.map { $0.counts.files }, events.map { $0.counts.files }.sorted(), "件数は減らない")
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

    /// OS 呼び出しが戻らない間は停止を確定しない。利用者が強制中止したときだけ確定し、次のスキャンを許す。
    func testForceStopOnlyWhileCancellingAndDropsLateResults() async throws {
        let fs = makeTree()
        let gate = Gate()
        let entered = DispatchSemaphore(value: 0)
        fs.onList = { @Sendable path in
            if path == "/data/d0" {
                entered.signal()
                gate.wait()
            }
        }
        let coordinator = ScanCoordinator(provider: fs, configuration: configuration())
        let scope = ScanScope(rootPath: "/data", kind: .folder)!
        let stuck = try coordinator.start(scope: scope)
        blockingWait(entered)

        stuck.forceStop()
        XCTAssertEqual(stuck.currentState, .scanning, "キャンセル前の強制中止は効かない")
        stuck.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stuck.currentState, .cancelling, "OS 呼び出しが戻るまでは自動で確定しない")

        stuck.forceStop()
        let result = await stuck.waitUntilFinished()
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertTrue(result.wasForceStopped)
        let itemsAtStop = stuck.store.itemCount

        fs.onList = nil
        let next = try coordinator.start(scope: scope)
        gate.open()
        let nextResult = await next.waitUntilFinished()
        XCTAssertEqual(nextResult.state, .completed)
        XCTAssertFalse(nextResult.wasForceStopped)

        // 止まっていなかった旧スキャンのスレッドが戻っても、確定済みの結果は変わらない
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(stuck.store.itemCount, itemsAtStop)
        XCTAssertEqual(stuck.currentState, .cancelled)
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

    func testBoundedQueueProducerWaitsWhenFullAndCloseWakesIt() {
        let queue = BoundedQueue<Int>(capacity: 2)
        XCTAssertTrue(queue.put(1))
        XCTAssertTrue(queue.put(2))
        let thirdPut = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            queue.put(3)
            thirdPut.signal()
        }
        XCTAssertEqual(thirdPut.wait(timeout: .now() + 0.2), .timedOut, "満杯の間は追加を待たせる")
        XCTAssertEqual(queue.take(), 1)
        XCTAssertEqual(thirdPut.wait(timeout: .now() + 5), .success, "空きができたら追加が進む")

        let blocked = DispatchSemaphore(value: 0)
        // いまは 2 と 3 で満杯。待っている生産者は close で起こされ、追加せずに失敗を返す
        DispatchQueue.global().async {
            XCTAssertFalse(queue.put(5), "閉じられた追加は失敗する")
            blocked.signal()
        }
        queue.close()
        XCTAssertEqual(blocked.wait(timeout: .now() + 5), .success, "close は待っている生産者を起こす")
        XCTAssertEqual([queue.take(), queue.take(), queue.take()], [2, 3, nil], "閉じても残りは取り出せる")
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
