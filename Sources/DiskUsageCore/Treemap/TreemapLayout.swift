import Foundation

public struct TreemapRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

public struct TreemapTile: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case item(ItemID)
        /// 小さすぎて描画しない項目のまとまり。一覧から到達させる。
        case others(count: Int, bytes: Int64)
    }

    public let content: Content
    public let bytes: Int64
    public let rect: TreemapRect
}

public struct TreemapResult: Equatable, Sendable {
    public let tiles: [TreemapTile]
    /// 「その他」にまとめた項目。タイルが小さすぎて描けない場合も、一覧への導線に使う。
    public let others: (count: Int, bytes: Int64)?
    /// タイルとして描いた個別項目の数（一覧の何件目から「その他」かを示す）
    public let itemTileCount: Int

    public static let empty = TreemapResult(tiles: [], others: nil, itemTileCount: 0)

    public static func == (lhs: TreemapResult, rhs: TreemapResult) -> Bool {
        lhs.tiles == rhs.tiles && lhs.itemTileCount == rhs.itemTileCount
            && lhs.others?.count == rhs.others?.count && lhs.others?.bytes == rhs.others?.bytes
    }
}

/// 既知の割り当て済みサイズに比例した squarified treemap を計算する。
///
/// - サイズ 0・不明の項目には面積を与えない（推測で埋めない）。一覧側で到達できるようにする。
/// - 面積が `minimumTileArea` 未満になる項目と、`maximumTiles` を超える項目は「その他」にまとめる。
/// - 同じサイズの項目は、呼び出し側（一覧と同じサイズ順）の並びを保つ。
public enum TreemapLayout {
    /// - Parameter remainder: 呼び出し側で事前に省いた、サイズが分かる 0 より大きい項目の件数と合計。
    ///   「その他」に含める。
    public static func layout(
        _ entries: [(id: ItemID, bytes: Int64?)],
        in bounds: TreemapRect,
        minimumTileArea: Double = 64,
        maximumTiles: Int = 400,
        remainder: (count: Int, bytes: Int64) = (0, 0)
    ) -> TreemapResult {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.x.isFinite, bounds.y.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .empty }

        let positive = entries.enumerated()
            .compactMap { offset, entry -> (order: Int, id: ItemID, bytes: Int64)? in
                guard let bytes = entry.bytes, bytes > 0 else { return nil }
                return (offset, entry.id, bytes)
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.order < $1.order }

        let remainderBytes = max(0, remainder.bytes)
        let remainderCount = remainderBytes > 0 ? max(1, remainder.count) : 0
        let total = positive.reduce(Double(remainderBytes)) { $0 + Double($1.bytes) }
        guard total > 0 else { return .empty }

        // 上限は溢れる場合だけ適用し、溢れるときは「その他」の1枠を残す
        let tileBudget = max(1, maximumTiles)
        let overflows = positive.count + (remainderCount > 0 ? 1 : 0) > tileBudget
        let itemBudget = overflows ? tileBudget - 1 : positive.count

        let scale = bounds.area / total
        var shown: [(content: TreemapTile.Content, bytes: Int64)] = []
        var othersCount = remainderCount
        var othersBytes = remainderBytes
        for entry in positive {
            if shown.count < itemBudget, Double(entry.bytes) * scale >= minimumTileArea {
                shown.append((.item(entry.id), entry.bytes))
            } else {
                othersCount += 1
                othersBytes = saturatingAdd(othersBytes, entry.bytes)
            }
        }
        let itemTileCount = shown.count
        if othersCount > 0 {
            // squarify は面積の降順を前提にするため、「その他」も大きさの順に置く
            let position = shown.firstIndex { $0.bytes < othersBytes } ?? shown.count
            shown.insert((.others(count: othersCount, bytes: othersBytes), othersBytes), at: position)
        }

        let areas = shown.map { Double($0.bytes) * scale }
        let rects = squarify(areas, in: bounds)
        let tiles = zip(shown, rects).map { TreemapTile(content: $0.content, bytes: $0.bytes, rect: $1) }
        return TreemapResult(
            tiles: tiles,
            others: othersCount > 0 ? (othersCount, othersBytes) : nil,
            itemTileCount: itemTileCount
        )
    }

    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }

    /// Bruls らの squarified 配置。面積は降順で渡す。
    static func squarify(_ areas: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var result: [TreemapRect] = []
        result.reserveCapacity(areas.count)
        var remaining = bounds
        var row: [Double] = []
        var index = 0

        func worst(_ row: [Double], side: Double) -> Double {
            guard let maxArea = row.max(), let minArea = row.min(), side > 0, minArea > 0 else { return .infinity }
            let sum = row.reduce(0, +)
            let sideSquared = side * side
            let sumSquared = sum * sum
            return max(sideSquared * maxArea / sumSquared, sumSquared / (sideSquared * minArea))
        }

        func place(_ row: [Double]) {
            let sum = row.reduce(0, +)
            guard sum > 0 else { return }
            if remaining.width >= remaining.height {
                // 左端に縦一列で置く
                let columnWidth = remaining.height > 0 ? sum / remaining.height : 0
                var y = remaining.y
                for area in row {
                    let height = columnWidth > 0 ? area / columnWidth : 0
                    result.append(TreemapRect(x: remaining.x, y: y, width: columnWidth, height: height))
                    y += height
                }
                remaining.x += columnWidth
                remaining.width = max(0, remaining.width - columnWidth)
            } else {
                // 上端に横一行で置く
                let rowHeight = remaining.width > 0 ? sum / remaining.width : 0
                var x = remaining.x
                for area in row {
                    let width = rowHeight > 0 ? area / rowHeight : 0
                    result.append(TreemapRect(x: x, y: remaining.y, width: width, height: rowHeight))
                    x += width
                }
                remaining.y += rowHeight
                remaining.height = max(0, remaining.height - rowHeight)
            }
        }

        while index < areas.count {
            let side = min(remaining.width, remaining.height)
            let candidate = row + [areas[index]]
            if row.isEmpty || worst(candidate, side: side) <= worst(row, side: side) {
                row = candidate
                index += 1
            } else {
                place(row)
                row.removeAll()
            }
        }
        if !row.isEmpty {
            place(row)
        }
        return result
    }
}
