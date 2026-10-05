import AppKit
import SwiftUI
import DiskUsageCore

/// 読み取れなかった場所、または方針により範囲外とした場所の一覧。両者を混ぜずに示す。
struct LocationsSheet: View {
    let category: ItemCategory
    let session: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var page: LocatedItemPage?
    @State private var offset = 0
    private let pageSize = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if category == .problems {
                PermissionGuidance()
            }
            if let page {
                if page.items.isEmpty {
                    ContentUnavailableView("該当する場所はありません", systemImage: "checkmark.circle")
                } else {
                    Table(page.items) {
                        TableColumn("場所") { located in
                            Text(located.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(located.path)
                        }
                        TableColumn("状態") { located in
                            Text(state(of: located.item))
                                .foregroundStyle(category == .problems ? Color.orange : .secondary)
                        }
                        .width(min: 140, ideal: 200)
                        TableColumn("詳細") { located in
                            Text(located.item.errorDescription ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .width(min: 120, ideal: 220)
                    }
                    HStack {
                        Button("前へ") { load(offset - pageSize) }
                            .disabled(page.offset == 0)
                        Text("\(page.offset + 1)〜\(page.offset + page.items.count) 件目 / \(page.totalCount.formatted()) 件")
                            .monospacedDigit()
                        Button("次へ") { load(offset + pageSize) }
                            .disabled(page.offset + page.items.count >= page.totalCount)
                        Spacer()
                    }
                    .font(.callout)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
        .task { load(0) }
    }

    private var title: String {
        category == .problems ? "読み取れなかった場所" : "範囲外とした場所"
    }

    private var explanation: String {
        switch category {
        case .problems:
            return "アクセス拒否・読み取りエラー・クラウド上のみの項目です。これらの容量は集計に含まれず、読めなかったフォルダの中にある項目の数も分かりません。"
        case .excluded:
            return "別のボリューム、同じフォルダへの別経路、起動ディスクの別名経路など、二重に数えないため意図的に走査しなかった場所です。読み取りに失敗したわけではありません。外付けディスクは別の対象として選んでスキャンできます。"
        }
    }

    private func state(of item: ScanItem) -> String {
        if let reason = item.exclusionReason {
            return DisplayText.exclusion(reason)
        }
        switch item.accessState {
        case .denied: return "アクセス拒否"
        case .error: return "読み取りエラー"
        case .notScanned: return "未走査（クラウド上のみなど）"
        case .readable: return "一部のみ走査"
        }
    }

    private func load(_ newOffset: Int) {
        offset = max(0, newOffset)
        let store = session.store
        let category = category
        let requested = offset
        let size = pageSize
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                store.locatedItems(category, offset: requested, limit: size)
            }.value
            if offset == requested {
                page = result
            }
        }
    }
}

/// フルディスクアクセスの案内。権限の拒否だけから原因を断定しない。
struct PermissionGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("アクセスが拒否された場所は、macOS のプライバシー設定でこのアプリに「フルディスクアクセス」を許可すると読めるようになる場合があります。許可しても、システムが保護している場所など、読めないままの場所もあります。原因はフォルダの権限設定など別のこともあります。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("プライバシーとセキュリティ設定を開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("システム設定の「フルディスクアクセス」を開きます。許可はご自身で行ってください。")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
