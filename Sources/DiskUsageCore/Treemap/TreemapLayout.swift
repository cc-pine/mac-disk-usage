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

/// 既知の割り当て済みサイズに比例した squarified treemap を計算する。
///
/// - サイズ 0・不明の項目には面積を与えない（推測で埋めない）。一覧側で到達できるようにする。
/// - 面積が `minimumTileArea` 未満になる項目と、`maximumTiles` を超える項目は「その他」にまとめる。
public enum TreemapLayout {
    /// - Parameter remainder: 呼び出し側で事前に省いた項目（件数と既知サイズ合計）。「その他」に含める。
    public static func layout(
        _ entries: [(id: ItemID, bytes: Int64?)],
        in bounds: TreemapRect,
        minimumTileArea: Double = 64,
        maximumTiles: Int = 400,
        remainder: (count: Int, bytes: Int64) = (0, 0)
    ) -> [TreemapTile] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let positive = entries.compactMap { entry -> (id: ItemID, bytes: Int64)? in
            guard let bytes = entry.bytes, bytes > 0 else { return nil }
            return (entry.id, bytes)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }

        let remainderBytes = max(0, remainder.bytes)
        let total = positive.reduce(Double(remainderBytes)) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }

        let scale = bounds.area / total
        var shown: [(content: TreemapTile.Content, bytes: Int64)] = []
        var othersCount = remainderBytes > 0 ? remainder.count : 0
        var othersBytes: Int64 = remainderBytes
        for entry in positive {
            let fitsCount = shown.count < max(1, maximumTiles - 1)
            if fitsCount, Double(entry.bytes) * scale >= minimumTileArea {
                shown.append((.item(entry.id), entry.bytes))
            } else {
                othersCount += 1
                othersBytes &+= entry.bytes
            }
        }
        if othersCount > 0 {
            shown.append((.others(count: othersCount, bytes: othersBytes), othersBytes))
        }

        let areas = shown.map { Double($0.bytes) * scale }
        let rects = squarify(areas, in: bounds)
        return zip(shown, rects).map { TreemapTile(content: $0.content, bytes: $0.bytes, rect: $1) }
    }

    /// Bruls らの squarified 配置。面積は降順で渡す。
    static func squarify(_ areas: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var result: [TreemapRect] = []
        result.reserveCapacity(areas.count)
        var remaining = bounds
        var row: [Double] = []
        var index = 0

        func worst(_ row: [Double], side: Double) -> Double {
            guard let maxArea = row.max(), let minArea = row.min(), side > 0 else { return .infinity }
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
