import SwiftUI
import DiskUsageCore

/// 表示中フォルダの直下をサイズ順に並べる。巨大なフォルダはページ単位で表示する。
struct ItemListView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // 読み込み中も前の表を表示したままにし、表を作り直して選択やキーボードの焦点を失わない
            if let page = model.children, page.totalCount > 0 || model.isLoadingView {
                ItemTable(items: page.items, total: totalKnownBytes, moved: model.movedItems, selection: $model.selectionID) { item in
                    model.activate(item)
                }
                .opacity(model.isLoadingView ? 0.6 : 1)
                PageBar(page: page, pageSize: ScanViewModel.pageSize) { offset in
                    model.showChildrenPage(offset: offset)
                }
            } else if let directory = model.directory {
                ContentUnavailableView(emptyTitle(directory), systemImage: "folder", description: Text(directory.errorDescription ?? ""))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var totalKnownBytes: Int64 {
        model.directory?.displayAllocatedBytes ?? 0
    }

    private func emptyTitle(_ directory: ScanItem) -> String {
        switch directory.accessState {
        case .denied: return "このフォルダは読み取れませんでした"
        case .error: return "このフォルダの読み取り中にエラーが起きました"
        case .notScanned: return "このフォルダは走査していません"
        case .readable:
            switch directory.traversalState {
            case .pending: return "走査中です"
            case .partial where directory.sizeSummary.hasUnvisitedDescendants:
                return "走査を中止したため、このフォルダの中身は取得していません"
            case .excluded: return "このフォルダは除外したため走査していません"
            default: return "空のフォルダです"
            }
        }
    }
}

/// サイズ順の表。行の選択は詳細パネルに、ダブルクリック・Return はフォルダを開く操作に接続する。
struct ItemTable: View {
    let items: [ScanItem]
    let total: Int64
    var moved: Set<ItemID> = []
    @Binding var selection: ItemID?
    var showsPath: ((ScanItem) -> String?)? = nil
    let activate: (ScanItem) -> Void

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("名前") { item in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let path = showsPath?(item) {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } icon: {
                    Image(systemName: ItemIcon.name(for: item))
                        .foregroundStyle(ItemIcon.color(for: item))
                }
            }
            TableColumn("割り当て済みサイズ") { item in
                Text(DisplayText.size(of: item))
                    .monospacedDigit()
                    .foregroundStyle(item.displayAllocatedBytes == nil || moved.contains(item.id) ? .secondary : .primary)
                    .strikethrough(moved.contains(item.id))
            }
            .width(min: 120, ideal: 160)
            TableColumn("割合") { item in
                ShareBar(bytes: item.displayAllocatedBytes, total: total)
            }
            .width(min: 60, ideal: 100)
            TableColumn("状態") { item in
                Text(moved.contains(item.id) ? "ゴミ箱へ移動済み" : DisplayText.access(of: item))
                    .foregroundStyle(item.accessState == .readable && !moved.contains(item.id) ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: ItemID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let item = items.first(where: { $0.id == id }) {
                activate(item)
            }
        }
        .onKeyPress(.return) {
            guard let selection, let item = items.first(where: { $0.id == selection }) else { return .ignored }
            activate(item)
            return .handled
        }
    }
}

/// 既知合計に対する割合の簡易バー。不明・合計 0 の場合は描かない。
private struct ShareBar: View {
    let bytes: Int64?
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        guard let bytes, total > 0, bytes > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }
}

struct PageBar: View {
    let page: ItemPage
    let pageSize: Int
    let go: (Int) -> Void

    var body: some View {
        if page.totalCount > pageSize || page.isProvisional {
            HStack {
                Button {
                    go(page.offset - pageSize)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(page.offset == 0)
                .help("前のページ")
                Text("\(page.offset + 1)〜\(page.offset + page.items.count) 件目 / \(page.totalCount.formatted()) 件")
                    .monospacedDigit()
                Button {
                    go(page.offset + pageSize)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(page.offset + page.items.count >= page.totalCount)
                .help("次のページ")
                if page.isProvisional {
                    Text("上位の一部だけを表示しています（全件の一覧はスキャン完了後に準備します）")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

enum ItemIcon {
    static func name(for item: ScanItem) -> String {
        switch item.kind {
        case .file: return "doc"
        case .directory:
            if item.isPackage { return "shippingbox" }
            if item.traversalState == .excluded { return "folder.badge.minus" }
            return item.accessState == .readable ? "folder" : "folder.badge.questionmark"
        case .symbolicLink: return "arrowshape.turn.up.right"
        case .other: return item.accessState == .readable ? "gearshape" : "questionmark.square.dashed"
        }
    }

    static func color(for item: ScanItem) -> Color {
        if item.accessState != .readable { return .orange }
        switch item.kind {
        case .directory: return .accentColor
        default: return .secondary
        }
    }
}
