import SwiftUI
import DiskUsageCore

/// 表示中フォルダの直下を、既知の割り当て済みサイズに比例して描く。
///
/// クリックで選択、ダブルクリックでフォルダを開く。小さい項目は「その他」にまとめ、
/// 選ぶと一覧の該当行へ移る。同じ操作は一覧とキーボードでも行える。
struct TreemapView: View {
    @Environment(ScanViewModel.self) private var model
    private let othersRowHeight: Double = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let directory = model.directory, directory.isSizeIncomplete {
                Label(L10n.treemapPartial, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            GeometryReader { proxy in
                if let snapshot = model.treemap {
                    let result = layout(snapshot, in: proxy.size)
                    if result.tiles.isEmpty, !model.isLoadingView {
                        ContentUnavailableView(
                            L10n.treemapEmptyTitle,
                            systemImage: "square.grid.2x2",
                            description: Text(L10n.treemapEmptyDetail)
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            TreemapCanvas(
                                tiles: result.tiles,
                                items: Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) }),
                                moved: model.movedItems,
                                selection: model.selectionID,
                                select: { select($0, result: result) },
                                activate: { activate($0, snapshot: snapshot) }
                            )
                            // 読み込み中は前のフォルダの配置を薄く残す
                            .opacity(model.isLoadingView ? 0.5 : 1)
                            .overlay {
                                if model.isLoadingView {
                                    ProgressView()
                                }
                            }
                            if let others = result.others {
                                // 「その他」のタイルが小さすぎて押せない場合も一覧へ移れるようにする
                                Button(L10n.treemapOthersLink(count: others.count, size: ByteFormatting.string(others.bytes))) {
                                    model.showOthersInList(firstIndex: result.itemTileCount)
                                }
                                .buttonStyle(.link)
                                .frame(height: othersRowHeight - 6)
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
    }

    /// 「その他」がある場合だけ、その案内行の高さを差し引いて配置し直す。
    private func layout(_ snapshot: TreemapSnapshot, in size: CGSize) -> TreemapResult {
        func compute(height: Double) -> TreemapResult {
            TreemapLayout.layout(
                snapshot.items.map { (id: $0.id, bytes: $0.displayAllocatedBytes) },
                in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: max(0, height)),
                minimumTileArea: 48,
                maximumTiles: ScanViewModel.treemapLimit,
                remainder: (snapshot.remainderCount, snapshot.remainderBytes)
            )
        }
        let full = compute(height: Double(size.height))
        return full.others == nil ? full : compute(height: Double(size.height) - othersRowHeight)
    }

    private func select(_ tile: TreemapTile, result: TreemapResult) {
        switch tile.content {
        case .item(let id):
            model.selectionID = id
        case .others:
            model.showOthersInList(firstIndex: result.itemTileCount)
        }
    }

    private func activate(_ tile: TreemapTile, snapshot: TreemapSnapshot) {
        guard case .item(let id) = tile.content, let item = snapshot.items.first(where: { $0.id == id }) else { return }
        model.activate(item)
    }
}

private struct TreemapCanvas: View {
    let tiles: [TreemapTile]
    let items: [ItemID: ScanItem]
    let moved: Set<ItemID>
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
        // 1回目のクリックですぐ選択し（ダブルクリックの判定を待たない）、2回目で開く
        .gesture(SpatialTapGesture(count: 2).onEnded { value in
            if let tile = tile(at: value.location) {
                activate(tile)
            }
        })
        .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
            if let tile = tile(at: value.location) {
                select(tile)
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.treemapAccessibility)
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
            if moved.contains(id) {
                return "\(name)\n\(L10n.movedToTrash)"
            }
            return "\(name)\n\(ByteFormatting.string(tile.bytes))"
        case .others(let count, let bytes):
            return "\(L10n.treemapOthersTile(count: count))\n\(ByteFormatting.string(bytes))"
        }
    }

    private func fillColor(_ tile: TreemapTile) -> Color {
        switch tile.content {
        case .others:
            return Color.gray.opacity(0.6)
        case .item(let id):
            guard let item = items[id] else { return .gray }
            if moved.contains(id) {
                return Color.gray.opacity(0.35)
            }
            if item.kind == .directory {
                return item.isSizeIncomplete ? Color.orange.opacity(0.75) : Color.blue.opacity(0.75)
            }
            return Color.teal.opacity(0.75)
        }
    }
}
