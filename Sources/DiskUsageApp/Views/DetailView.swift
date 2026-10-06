import SwiftUI
import DiskUsageCore

/// 選択項目の詳細と、Finder 表示・ゴミ箱へ移動の操作。
struct DetailView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        if let item = model.selectedItem {
            Form {
                Section {
                    LabeledContent(L10n.detailName, value: item.name)
                    LabeledContent(L10n.detailLocation) {
                        Text(model.selectedPath ?? L10n.unknown)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                    LabeledContent(L10n.detailKind, value: DisplayText.kind(of: item))
                }
                Section(L10n.detailSize) {
                    LabeledContent(L10n.detailAllocated, value: DisplayText.allocatedSizeDetail(of: item))
                    LabeledContent(L10n.detailLogical, value: DisplayText.logicalSize(of: item))
                    if item.kind == .directory, item.sizeSummary.unknownAllocatedItems > 0 {
                        LabeledContent(L10n.detailUnknownItems, value: L10n.itemsCount(item.sizeSummary.unknownAllocatedItems))
                    }
                    if item.kind == .directory, item.sizeSummary.unreadableLocations > 0 {
                        LabeledContent(L10n.detailUnreadableLocations, value: L10n.locationsCount(item.sizeSummary.unreadableLocations))
                    }
                }
                Section(L10n.detailDates) {
                    LabeledContent(L10n.detailModified, value: DisplayText.date(item.modifiedDate))
                    LabeledContent(L10n.detailCreated, value: DisplayText.date(item.createdDate))
                }
                Section(L10n.detailStatus) {
                    Text(DisplayText.access(of: item))
                    if let error = item.errorDescription {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                    if let reason = item.exclusionReason {
                        Text(reason == .otherVolume
                             ? L10n.detailExcludedOtherVolume
                             : L10n.detailExcludedByRule)
                            .foregroundStyle(.secondary)
                    }
                    if item.accessState == .denied {
                        PermissionGuidance()
                    }
                    if model.movedItems.contains(item.id) {
                        Label(L10n.movedToTrash, systemImage: "trash")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        model.revealSelectionInFinder()
                    } label: {
                        Label(L10n.menuShowInFinder, systemImage: "folder")
                    }
                    .disabled(!model.canRevealSelection)

                    if model.tab != .list, item.parentID != nil {
                        Button {
                            model.showSelectionInFolder()
                        } label: {
                            Label(L10n.menuShowInFolder, systemImage: "list.bullet.indent")
                        }
                        .help(L10n.showInFolderHelp)
                    }

                    TrashButton()
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(L10n.selectItem, systemImage: "info.circle")
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
                Label(model.isTrashing ? L10n.moving : L10n.moveToTrashEllipsis, systemImage: "trash")
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
