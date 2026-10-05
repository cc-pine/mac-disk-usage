import XCTest
@testable import DiskUsageCore

final class TreemapLayoutTests: XCTestCase {
    private let bounds = TreemapRect(x: 0, y: 0, width: 600, height: 400)

    private func entries(_ sizes: [Int64?]) -> [(id: ItemID, bytes: Int64?)] {
        sizes.enumerated().map { (ItemID(Int32($0.offset)), $0.element) }
    }

    private func assertInside(_ tiles: [TreemapTile], _ bounds: TreemapRect, file: StaticString = #filePath, line: UInt = #line) {
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.rect.x, bounds.x - 0.0001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(tile.rect.y, bounds.y - 0.0001, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.rect.x + tile.rect.width, bounds.x + bounds.width + 0.0001, file: file, line: line)
            XCTAssertLessThanOrEqual(tile.rect.y + tile.rect.height, bounds.y + bounds.height + 0.0001, file: file, line: line)
        }
    }

    func testAreasAreProportionalAndInsideBounds() {
        let result = TreemapLayout.layout(entries([600, 300, 100]), in: bounds, minimumTileArea: 1)
        XCTAssertEqual(result.tiles.count, 3)
        XCTAssertNil(result.others)
        let totalArea = result.tiles.reduce(0) { $0 + $1.rect.area }
        XCTAssertEqual(totalArea, bounds.area, accuracy: 0.001)
        for tile in result.tiles {
            XCTAssertEqual(tile.rect.area / bounds.area, Double(tile.bytes) / 1000, accuracy: 0.0001)
        }
        assertInside(result.tiles, bounds)
    }

    func testNonZeroOriginStaysInside() {
        let shifted = TreemapRect(x: 50, y: 20, width: 300, height: 200)
        let result = TreemapLayout.layout(entries((1...25).map { Int64($0 * 13) }), in: shifted, minimumTileArea: 0)
        assertInside(result.tiles, shifted)
    }

    func testTilesDoNotOverlap() {
        let result = TreemapLayout.layout(entries((1...30).map { Int64($0 * 37 % 101 + 1) }), in: bounds, minimumTileArea: 0)
        let tiles = result.tiles
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                let a = tiles[i].rect, b = tiles[j].rect
                let overlapX = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapY = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                XCTAssertFalse(overlapX > 0.001 && overlapY > 0.001, "tile \(i) と \(j) が重なる")
            }
        }
    }

    func testZeroAndUnknownGetNoArea() {
        let result = TreemapLayout.layout(entries([0, nil, 10]), in: bounds)
        XCTAssertEqual(result.tiles.map(\.content), [.item(ItemID(2))])
    }

    func testAllZeroIsEmpty() {
        XCTAssertTrue(TreemapLayout.layout(entries([0, nil]), in: bounds).tiles.isEmpty)
        XCTAssertTrue(TreemapLayout.layout([], in: bounds).tiles.isEmpty)
    }

    func testSmallItemsAreGroupedIntoOthers() {
        let result = TreemapLayout.layout(entries([1_000_000] + Array(repeating: 1, count: 500)), in: bounds, minimumTileArea: 64)
        XCTAssertEqual(result.tiles.count, 2)
        XCTAssertEqual(result.itemTileCount, 1)
        XCTAssertEqual(result.others?.count, 500)
        XCTAssertEqual(result.others?.bytes, 500)
    }

    func testMaximumTilesAppliesOnlyWhenOverflowing() {
        let exact = TreemapLayout.layout(entries(Array(repeating: 100, count: 50)), in: bounds, minimumTileArea: 0, maximumTiles: 50)
        XCTAssertEqual(exact.tiles.count, 50)
        XCTAssertNil(exact.others, "ちょうど上限なら「その他」を作らない")

        let over = TreemapLayout.layout(entries(Array(repeating: 100, count: 1_000)), in: bounds, minimumTileArea: 0, maximumTiles: 50)
        XCTAssertEqual(over.tiles.count, 50)
        XCTAssertEqual(over.itemTileCount, 49)
        XCTAssertEqual(over.others?.count, 951)

        let single = TreemapLayout.layout(entries([5, 4, 3]), in: bounds, minimumTileArea: 0, maximumTiles: 1)
        XCTAssertEqual(single.tiles.count, 1)
        XCTAssertEqual(single.others?.count, 3)
    }

    func testRemainderJoinsOthersAndKeepsProportions() {
        let result = TreemapLayout.layout(entries([500, 300]), in: bounds, minimumTileArea: 0, remainder: (count: 10, bytes: 200))
        XCTAssertEqual(result.others?.count, 10)
        XCTAssertEqual(result.others?.bytes, 200)
        XCTAssertEqual(result.tiles.map(\.bytes), [500, 300, 200], "「その他」もサイズ順の位置に置く")
        let others = result.tiles.first { if case .others = $0.content { return true } else { return false } }!
        XCTAssertEqual(others.rect.area / bounds.area, 0.2, accuracy: 0.0001)
    }

    func testLargeOthersIsPlacedBySize() {
        let result = TreemapLayout.layout(entries([100, 50]), in: bounds, minimumTileArea: 0, remainder: (count: 1_000, bytes: 10_000))
        if case .others = result.tiles.first?.content {} else {
            XCTFail("最大の「その他」は先頭に置く")
        }
    }

    func testEqualSizesKeepCallerOrder() {
        let input: [(id: ItemID, bytes: Int64?)] = [(ItemID(9), 10), (ItemID(3), 10), (ItemID(5), 10)]
        let result = TreemapLayout.layout(input, in: bounds, minimumTileArea: 0)
        XCTAssertEqual(result.tiles.map(\.content), [.item(ItemID(9)), .item(ItemID(3)), .item(ItemID(5))])
    }

    func testSkewedSizesStillExposeOthers() {
        let result = TreemapLayout.layout(entries([1_000_000_000_000_000] + Array(repeating: 1, count: 999)), in: bounds)
        XCTAssertEqual(result.others?.count, 999, "描けないほど小さくても一覧への導線を返す")
        assertInside(result.tiles, bounds)
    }

    func testOverflowSaturatesAndBadBoundsAreRejected() {
        let result = TreemapLayout.layout(entries([.max, .max, 1]), in: bounds, minimumTileArea: 0, maximumTiles: 1)
        XCTAssertEqual(result.others?.bytes, .max)
        XCTAssertTrue(TreemapLayout.layout(entries([10]), in: TreemapRect(x: 0, y: 0, width: .infinity, height: 10)).tiles.isEmpty)
        XCTAssertTrue(TreemapLayout.layout(entries([10]), in: TreemapRect(x: 0, y: 0, width: 0, height: 100)).tiles.isEmpty)
    }
}
