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
                    ContentUnavailableView(L10n.noMatchingLocations, systemImage: "checkmark.circle")
                } else {
                    Table(page.items) {
                        TableColumn(L10n.columnLocation) { located in
                            Text(located.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(located.path)
                        }
                        TableColumn(L10n.columnStatus) { located in
                            Text(state(of: located.item))
                                .foregroundStyle(category == .problems ? Color.orange : .secondary)
                        }
                        .width(min: 140, ideal: 200)
                        TableColumn(L10n.columnDetails) { located in
                            Text(located.item.errorDescription ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .width(min: 120, ideal: 220)
                    }
                    HStack {
                        Button(L10n.previous) { load(page.offset - pageSize) }
                            .disabled(isLoading || page.offset == 0)
                        Text(L10n.pageRange(from: page.offset + 1, to: page.offset + page.items.count, total: page.totalCount))
                            .monospacedDigit()
                        Button(L10n.next) { load(page.offset + pageSize) }
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
                Button(L10n.close) { dismiss() }
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
        category == .problems ? L10n.problemsTitle : L10n.excludedTitle
    }

    private var explanation: String {
        switch category {
        case .problems:
            return L10n.problemsExplanation
        case .excluded:
            return L10n.excludedExplanation
        }
    }

    private func state(of item: ScanItem) -> String {
        if let reason = item.exclusionReason {
            return DisplayText.exclusion(reason)
        }
        switch item.accessState {
        case .denied: return L10n.accessDenied
        case .error: return L10n.accessError
        case .notScanned: return L10n.accessNotScannedCloud
        case .readable: return L10n.traversalPartial
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
            Text(L10n.permissionGuidance)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.permissionSteps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.openFullDiskAccess) {
                let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security")
                if let fullDiskAccess, NSWorkspace.shared.open(fullDiskAccess) {
                    return
                }
                if let privacy {
                    NSWorkspace.shared.open(privacy)
                }
            }
            .help(L10n.openFullDiskAccessHelp)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
