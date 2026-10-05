import SwiftUI
import DiskUsageCore

/// 表示中フォルダの直下を、既知の割り当て済みサイズに比例して描く。
///
/// クリックで選択、ダブルクリックでフォルダを開く。小さい項目は「その他」にまとめ、
/// 選ぶと一覧の該当ページへ移る。同じ操作は一覧とキーボードでも行える。
struct TreemapView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let directory = model.directory, directory.isSizeIncomplete {
                Label("部分的な結果です。読めなかった場所・未走査の場所は面積に含みません。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            GeometryReader { proxy in
                let result = layout(in: proxy.size)
                if result.tiles.isEmpty {
                    ContentUnavailableView(
                        "表示できる容量がありません",
                        systemImage: "square.grid.2x2",
                        description: Text("このフォルダの直下に、サイズが分かる 0 bytes より大きい項目がありません。一覧ではすべての項目を確認できます。")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        TreemapCanvas(
                            tiles: result.tiles,
                            items: itemsByID,
                            selection: model.selectionID,
                            select: { select($0, result: result) },
                            activate: activate
                        )
                        if let others = result.others {
                            // 「その他」のタイルが小さすぎて押せない場合も一覧へ移れるようにする
                            Button("その他 \(others.count.formatted()) 件（\(ByteFormatting.string(others.bytes))）を一覧で表示") {
                                model.showOthersInList(firstIndex: result.itemTileCount)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    private var itemsByID: [ItemID: ScanItem] {
        Dictionary(uniqueKeysWithValues: (model.treemap?.items ?? []).map { ($0.id, $0) })
    }

    private func layout(in size: CGSize) -> TreemapResult {
        guard let snapshot = model.treemap, snapshot.directoryID == model.directoryID else { return .empty }
        // 「その他」の案内行の高さを差し引いて配置する
        let height = max(0, Double(size.height) - 28)
        return TreemapLayout.layout(
            snapshot.items.map { (id: $0.id, bytes: $0.displayAllocatedBytes) },
            in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: height),
            minimumTileArea: 48,
            maximumTiles: ScanViewModel.treemapLimit,
            remainder: (snapshot.remainderCount, snapshot.remainderBytes)
        )
    }

    private func select(_ tile: TreemapTile, result: TreemapResult) {
        switch tile.content {
        case .item(let id):
            model.selectionID = id
        case .others:
            model.showOthersInList(firstIndex: result.itemTileCount)
        }
    }

    private func activate(_ tile: TreemapTile) {
        guard case .item(let id) = tile.content, let item = itemsByID[id] else { return }
        model.activate(item)
    }
}

private struct TreemapCanvas: View {
    let tiles: [TreemapTile]
    let items: [ItemID: ScanItem]
    let selection: ItemID?
    let select: (TreemapTile) -> Void
    let activate: (TreemapTile) -> Void

    var body: some View {
        Canvas { context, _ in
            for tile in tiles {
                let rect = cgRect(tile.rect).insetBy(dx: 1, dy: 1)
                guard rect.width > 0, rect.height > 0 else { continue }
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(fillColor(tile)))
                if isSelected(tile) {
                    context.stroke(path, with: .color(.primary), lineWidth: 2.5)
                }
                if rect.width > 60, rect.height > 30 {
                    let text = Text(label(tile))
                        .font(.caption)
                        .foregroundStyle(.white)
                    context.draw(text, in: rect.insetBy(dx: 4, dy: 3))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in
                if let tile = tile(at: value.location) {
                    activate(tile)
                }
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                if let tile = tile(at: value.location) {
                    select(tile)
                }
            })
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("容量の Treemap。一覧タブで同じ項目をキーボード操作できます。")
    }

    private func tile(at point: CGPoint) -> TreemapTile? {
        tiles.first { cgRect($0.rect).contains(point) }
    }

    private func cgRect(_ rect: TreemapRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func isSelected(_ tile: TreemapTile) -> Bool {
        if case .item(let id) = tile.content {
            return id == selection
        }
        return false
    }

    private func label(_ tile: TreemapTile) -> String {
        switch tile.content {
        case .item(let id):
            let name = items[id]?.name ?? ""
            return "\(name)\n\(ByteFormatting.string(tile.bytes))"
        case .others(let count, let bytes):
            return "その他 \(count.formatted()) 件\n\(ByteFormatting.string(bytes))"
        }
    }

    private func fillColor(_ tile: TreemapTile) -> Color {
        switch tile.content {
        case .others:
            return Color.gray.opacity(0.6)
        case .item(let id):
            guard let item = items[id] else { return .gray }
            if item.kind == .directory {
                return item.isSizeIncomplete ? Color.orange.opacity(0.75) : Color.blue.opacity(0.75)
            }
            return Color.teal.opacity(0.75)
        }
    }
}
