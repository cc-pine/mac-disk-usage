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
                Section("ボリューム") {
                    ForEach(model.volumes) { volume in
                        VolumeRow(volume: volume)
                            .tag(ScanTarget.volume(volume))
                    }
                }
                if case .folder(let url)? = model.selectedTarget {
                    Section("フォルダ") {
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
                    Label("フォルダを選ぶ…", systemImage: "folder.badge.plus")
                }
                if let target = model.selectedTarget {
                    Text("対象: \(target.displayName)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.path)
                }
                HStack {
                    Button {
                        Task { await model.startScan() }
                    } label: {
                        Text(model.isScanActive ? "対象を変えてスキャン" : "スキャン")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartScan)
                    .help(model.isScanActive ? "実行中のスキャンを中止してから、選んだ対象をスキャンします" : "選んだ対象をスキャンします")
                }
                if model.isPreparingScan {
                    ProgressView("前のスキャンの停止を待っています…")
                        .controlSize(.small)
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
                    Label("ボリュームを再読み込み", systemImage: "arrow.clockwise")
                }
                .help("ボリューム一覧と容量情報を取り直す")
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
            return "容量情報を取得できません"
        }
        let used = capacity.usedBytes.map { "使用 \(ByteFormatting.string($0))" } ?? "使用量不明"
        let available = capacity.availableBytes.map { "空き \(ByteFormatting.string($0))" } ?? "空き容量不明"
        return "\(used) / 全体 \(ByteFormatting.string(total))・\(available)（\(DisplayText.time(capacity.fetchedAt)) 時点）"
    }
}
