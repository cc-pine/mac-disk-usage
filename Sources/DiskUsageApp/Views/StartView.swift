import SwiftUI
import DiskUsageCore

/// ボリュームとフォルダを選び、スキャンを始める。
struct StartView: View {
    @Environment(ScanViewModel.self) private var model
    @State private var choosingFolder = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $model.selectedTarget) {
                Section(L10n.sectionVolumes) {
                    ForEach(model.volumes) { volume in
                        VolumeRow(volume: volume)
                            .tag(ScanTarget.volume(volume))
                    }
                }
                // 選んだフォルダは、別の対象を選んでも一覧に残す
                if let url = model.chosenFolder {
                    Section(L10n.sectionFolder) {
                        Label(FileManager.default.displayName(atPath: url.path), systemImage: "folder")
                            .help(url.path)
                            .tag(ScanTarget.folder(url))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    choosingFolder = true
                } label: {
                    Label(L10n.chooseFolder, systemImage: "folder.badge.plus")
                }
                if let target = model.selectedTarget {
                    Text(L10n.target(target.displayName))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.path)
                }
                HStack {
                    Button {
                        model.requestStartScan()
                    } label: {
                        Text(model.isScanActive ? L10n.scanAnotherTarget : L10n.scan)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartScan)
                    .help(model.isScanActive ? L10n.scanAnotherTargetHelp : L10n.scanHelp)
                }
                if model.isPreparingScan {
                    ProgressView(L10n.waitingForPreviousScan)
                        .controlSize(.small)
                    if model.state == .cancelling {
                        // 前のスキャンの停止待ちが続く場合も、ここから強制中止できるようにする
                        ForceStopButton(requestedAt: model.cancelRequestedAt) {
                            model.forceStopScan()
                        }
                    }
                }
            }
            .padding(12)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.chooseFolder(url)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.loadVolumes()
                } label: {
                    Label(L10n.reloadVolumes, systemImage: "arrow.clockwise")
                }
                .help(L10n.reloadVolumesHelp)
            }
        }
    }
}

private struct VolumeRow: View {
    let volume: VolumeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(volume.name, systemImage: volume.isStartupDisk ? "internaldrive.fill" : "externaldrive")
            Text(capacityText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(volume.path)
    }

    private var capacityText: String {
        let capacity = volume.capacity
        guard let total = capacity.totalBytes else {
            return L10n.capacityUnavailable
        }
        let used = capacity.usedBytes.map { L10n.used(ByteFormatting.string($0)) } ?? L10n.usedUnknown
        let available = capacity.availableBytes.map { L10n.available(ByteFormatting.string($0)) } ?? L10n.availableUnknown
        return L10n.volumeRow(used: used, total: ByteFormatting.string(total), available: available, time: DisplayText.time(capacity.fetchedAt))
    }
}
