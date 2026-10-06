import AppKit
import SwiftUI
import DiskUsageCore

/// 読み取れなかった場所、または方針により範囲外とした場所の一覧。両者を混ぜずに示す。
///
/// 走査中は版が進むたびに表示中のページを読み直す。別のスキャンに切り替わったら呼び出し側で閉じる。
struct LocationsSheet: View {
    let category: ItemCategory
    let session: ScanSession
    /// 走査の進み具合。変わったら表示中のページを読み直す
    let revision: Int
    @Environment(\.dismiss) private var dismiss
    @State private var page: LocatedItemPage?
    @State private var isLoading = false
    private let pageSize = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if category == .problems, page?.items.contains(where: { $0.item.accessState == .denied }) == true {
                PermissionGuidance()
            }
            if let page {
                if page.totalCount == 0 {
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
                        Button("前へ") { load(page.offset - pageSize) }
                            .disabled(isLoading || page.offset == 0)
                        Text("\(page.offset + 1)〜\(page.offset + page.items.count) 件目 / \(page.totalCount.formatted()) 件")
                            .monospacedDigit()
                        Button("次へ") { load(page.offset + pageSize) }
                            .disabled(isLoading || page.offset + page.items.count >= page.totalCount)
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
        .onChange(of: revision) {
            load(page?.offset ?? 0)
        }
    }

    private var title: String {
        category == .problems ? "情報を取得できなかった場所" : "除外した場所"
    }

    private var explanation: String {
        switch category {
        case .problems:
            return "アクセス拒否・読み取りエラーの場所と、ダウンロードを避けるため走査しなかったクラウド上のみの項目です。読み取れなかった部分の容量は集計に含まれず、読み取れなかったフォルダの中にある項目の数も分かりません。"
        case .excluded:
            return "二重に数えないため、または走査範囲の規則により、意図的に走査しなかった場所です（別のボリューム、同じフォルダへの別経路、起動ディスクの別名経路、デバイス領域など）。読み取りに失敗したわけではありません。外付けディスクは、別の対象として選択するとスキャンできます。"
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

    private func load(_ requestedOffset: Int) {
        let store = session.store
        let category = category
        let size = pageSize
        let total = page?.totalCount
        // 末尾を越えたページを求めない
        var offset = max(0, requestedOffset)
        if let total, total > 0, offset >= total {
            offset = ((total - 1) / size) * size
        }
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                store.locatedItems(category, offset: offset, limit: size)
            }.value
            page = result
            isLoading = false
        }
    }
}

/// フルディスクアクセスの案内。権限の拒否だけから原因を断定しない。
struct PermissionGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("アクセスが拒否された場所は、このアプリに「フルディスクアクセス」を許可すると読み取れるようになる場合があります。ただし、システムが保護している場所は許可後も読み取れないことがあり、フォルダのアクセス権など別の原因によることもあります。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("許可する場合: 設定の一覧でこのアプリをオンにします（一覧にない場合は「+」で追加します）。その後アプリを再起動し、再スキャンしてください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("フルディスクアクセスの設定を開く") {
                let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security")
                if let fullDiskAccess, NSWorkspace.shared.open(fullDiskAccess) {
                    return
                }
                if let privacy {
                    NSWorkspace.shared.open(privacy)
                }
            }
            .help("システム設定の「プライバシーとセキュリティ」→「フルディスクアクセス」を開きます。許可はご自身で行ってください。")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
