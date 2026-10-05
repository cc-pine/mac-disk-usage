import SwiftUI
import DiskUsageCore

/// 選択項目の詳細と、Finder 表示・ゴミ箱へ移動の操作。
struct DetailView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            Form {
                Section {
                    LabeledContent("名前", value: item.name)
                    LabeledContent("場所") {
                        Text(model.selectedPath ?? "不明")
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                    LabeledContent("種類", value: DisplayText.kind(of: item))
                }
                Section("サイズ") {
                    LabeledContent("割り当て済み", value: DisplayText.allocatedSizeDetail(of: item))
                    LabeledContent("論理", value: DisplayText.logicalSize(of: item))
                    if item.kind == .directory, item.sizeSummary.unknownAllocatedItems > 0 {
                        LabeledContent("サイズ不明の項目", value: "\(item.sizeSummary.unknownAllocatedItems.formatted()) 件")
                    }
                    if item.kind == .directory, item.sizeSummary.unreadableLocations > 0 {
                        LabeledContent("読めなかった場所", value: "\(item.sizeSummary.unreadableLocations.formatted()) か所")
                    }
                }
                Section("日時") {
                    LabeledContent("更新", value: DisplayText.date(item.modifiedDate))
                    LabeledContent("作成", value: DisplayText.date(item.createdDate))
                }
                Section("状態") {
                    Text(DisplayText.access(of: item))
                    if let error = item.errorDescription {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                    if model.movedItems.contains(item.id) {
                        Label("ゴミ箱へ移動済み", systemImage: "trash")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        model.revealSelectionInFinder()
                    } label: {
                        Label("Finder で表示", systemImage: "folder")
                    }
                    .disabled(!model.canRevealSelection)

                    TrashButton()
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("項目を選択してください", systemImage: "info.circle")
        }
    }
}

private struct TrashButton: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        let availability = model.trashAvailability
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive) {
                model.requestTrash()
            } label: {
                Label(model.isTrashing ? "移動しています…" : "ゴミ箱へ移動…", systemImage: "trash")
            }
            .disabled(!isAvailable(availability))
            if case .failure(let reason)? = availability {
                Text(reason.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isAvailable(_ availability: Result<TrashCandidate, TrashBlockReason>?) -> Bool {
        if case .success? = availability {
            return true
        }
        return false
    }
}
