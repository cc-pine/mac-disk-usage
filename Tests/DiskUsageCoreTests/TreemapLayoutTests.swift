import XCTest
@testable import DiskUsageCore

final class TreemapLayoutTests: XCTestCase {
    private let bounds = TreemapRect(x: 0, y: 0, width: 600, height: 400)

    func testAreasAreProportionalAndInsideBounds() {
        let entries: [(id: ItemID, bytes: Int64?)] = [(ItemID(1), 600), (ItemID(2), 300), (ItemID(3), 100)]
        let tiles = TreemapLayout.layout(entries, in: bounds, minimumTileArea: 1)
        XCTAssertEqual(tiles.count, 3)
        let totalArea = tiles.reduce(0) { $0 + $1.rect.area }
        XCTAssertEqual(totalArea, bounds.area, accuracy: 0.001)
        for tile in tiles {
            XCTAssertEqual(tile.rect.area / bounds.area, Double(tile.bytes) / 1000, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(tile.rect.x, -0.0001)
            XCTAssertGreaterThanOrEqual(tile.rect.y, -0.0001)
            XCTAssertLessThanOrEqual(tile.rect.x + tile.rect.width, bounds.width + 0.0001)
            XCTAssertLessThanOrEqual(tile.rect.y + tile.rect.height, bounds.height + 0.0001)
        }
    }

    func testTilesDoNotOverlap() {
        let entries: [(id: ItemID, bytes: Int64?)] = (1...30).map { (ItemID(Int32($0)), Int64($0 * 37 % 101 + 1)) }
        let tiles = TreemapLayout.layout(entries, in: bounds, minimumTileArea: 0)
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
        let entries: [(id: ItemID, bytes: Int64?)] = [(ItemID(1), 0), (ItemID(2), nil), (ItemID(3), 10)]
        let tiles = TreemapLayout.layout(entries, in: bounds)
        XCTAssertEqual(tiles.map(\.content), [.item(ItemID(3))])
    }

    func testAllZeroIsEmpty() {
        let entries: [(id: ItemID, bytes: Int64?)] = [(ItemID(1), 0), (ItemID(2), nil)]
        XCTAssertTrue(TreemapLayout.layout(entries, in: bounds).isEmpty)
        XCTAssertTrue(TreemapLayout.layout([], in: bounds).isEmpty)
    }

    func testSmallItemsAreGroupedIntoOthers() {
        var entries: [(id: ItemID, bytes: Int64?)] = [(ItemID(0), 1_000_000)]
        for i in 1...500 {
            entries.append((ItemID(Int32(i)), 1))
        }
        let tiles = TreemapLayout.layout(entries, in: bounds, minimumTileArea: 64)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles.last?.content, .others(count: 500, bytes: 500))
    }

    func testMaximumTilesIsRespected() {
        let entries: [(id: ItemID, bytes: Int64?)] = (0..<1_000).map { (ItemID(Int32($0)), 100) }
        let tiles = TreemapLayout.layout(entries, in: bounds, minimumTileArea: 0, maximumTiles: 50)
        XCTAssertEqual(tiles.count, 50)
        XCTAssertEqual(tiles.last?.content, .others(count: 951, bytes: 95_100))
    }

    func testDegenerateBounds() {
        let entries: [(id: ItemID, bytes: Int64?)] = [(ItemID(1), 10)]
        XCTAssertTrue(TreemapLayout.layout(entries, in: TreemapRect(x: 0, y: 0, width: 0, height: 100)).isEmpty)
    }
}
