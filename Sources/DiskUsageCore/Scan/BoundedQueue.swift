import Foundation

/// 上限付きの FIFO キュー。満杯なら `put` で生産者を待たせ、要素を破棄しない。
final class BoundedQueue<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer: [Element] = []
    private var head = 0
    private var isClosed = false
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// 空きができるまで待って追加する。閉じた後の追加は false を返す。
    @discardableResult
    func put(_ element: Element) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count - head >= capacity, !isClosed {
            condition.wait()
        }
        guard !isClosed else { return false }
        buffer.append(element)
        condition.broadcast()
        return true
    }

    /// 要素が来るまで待って取り出す。閉じられて空になったら nil。
    func take() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        while buffer.count - head == 0, !isClosed {
            condition.wait()
        }
        guard buffer.count - head > 0 else { return nil }
        let element = buffer[head]
        head += 1
        if head > 64, head * 2 > buffer.count {
            buffer.removeFirst(head)
            head = 0
        }
        condition.broadcast()
        return element
    }

    /// これ以上追加しない。残っている要素は `take` で取り出せる。
    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffer.count - head
    }
}
