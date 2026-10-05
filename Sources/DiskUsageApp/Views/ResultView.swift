import SwiftUI
import DiskUsageCore

/// スキャン結果。ヘッダー・パンくず・表示切り替え・ステータス領域から成る。
struct ResultView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ResultHeader()
            Divider()
            BreadcrumbBar()
            Divider()
            Picker("表示", selection: $model.tab) {
                ForEach(ResultTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Group {
                switch model.tab {
                case .list:
                    ItemListView()
                case .treemap:
                    TreemapView()
                case .largeFiles:
                    LargeFilesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusFooter()
        }
    }
}

private struct ResultHeader: View {
    @Environment(ScanViewModel.self) private var model
    @State private var showsExplanation = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.scannedTarget?.displayName ?? "")
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(DisplayText.state(model.state, isStale: model.result?.isStale ?? false))
                    .foregroundStyle(stateColor)
                if model.state == .failed, let reason = model.result?.failureDescription {
                    Text("原因: \(reason)。対象を選び直すか、アクセス権を確認してください。")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if model.result?.isStale == true {
                    Text("ゴミ箱へ移動した項目があります。最新の容量は再スキャンで確認してください。")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let root = model.scanRoot {
                    Text("走査項目の集計: \(DisplayText.size(of: root))")
                        .font(.callout)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let capacity = model.capacity, let total = capacity.totalBytes {
                    Text("ボリューム: 使用 \(ByteFormatting.string(capacity.usedBytes)) / 全体 \(ByteFormatting.string(total))")
                    Text("空き \(ByteFormatting.string(capacity.availableBytes))（\(DisplayText.time(capacity.fetchedAt)) 時点）")
                        .foregroundStyle(.secondary)
                } else {
                    Text("ボリューム容量情報を取得できません")
                        .foregroundStyle(.secondary)
                }
                Button("集計とボリューム使用量の違い") {
                    showsExplanation = true
                }
                .buttonStyle(.link)
                .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
                    AggregationExplanation()
                }
            }
            .font(.callout)
        }
        .padding(12)
    }

    private var stateColor: Color {
        if model.result?.isStale == true {
            return .orange
        }
        switch model.state {
        case .failed?: return .red
        case .completedWithErrors?, .cancelled?: return .orange
        default: return .secondary
        }
    }
}

/// 走査集計とボリューム使用量が一致しない理由の説明。
struct AggregationExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("走査項目の集計はボリュームの使用量と一致しないことがあります")
                .font(.headline)
            Text("・読めなかった場所や走査範囲外の場所は集計に含まれません。")
            Text("・APFS のクローンやハードリンクは共有ブロックを区別せず、パスごとに数えます。")
            Text("・スナップショットや purgeable 領域、システム領域の一部は走査で見えません。")
            Text("・割り当て済みサイズは、その項目だけが占める容量や、削除で空く容量を表すとは限りません。")
            Text("・ボリューム容量は macOS が報告する値で、取得時刻の時点のものです。")
        }
        .font(.callout)
        .padding()
        .frame(width: 420)
    }
}

private struct BreadcrumbBar: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("親フォルダへ（⌘↑）")
            .disabled(!model.canGoUp)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(item.name) {
                            model.open(item.id)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(item.id == model.directoryID ? .semibold : .regular)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct StatusFooter: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let progress = model.progress {
                let counts = progress.counts
                Text("ファイル \(counts.files.formatted()) 件")
                Text("フォルダ \(counts.directories.formatted()) 件")
                Text("問題 \(counts.problemItems.formatted()) 件")
                    .foregroundStyle(counts.problemItems > 0 ? .orange : .secondary)
                    .help("アクセス拒否・読み取りエラー・クラウド上のみなど、情報を取得できなかった項目の数")
                Text("範囲外 \(counts.excludedItems.formatted()) 件")
                    .help("別ボリュームや別経路など、方針により走査しなかった場所の数")
                ElapsedText(progress: progress)
                if let finished = progress.finishedAt {
                    Text("\(DisplayText.time(progress.startedAt))〜\(DisplayText.time(finished))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("開始 \(DisplayText.time(progress.startedAt))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isScanActive {
                ProgressView()
                    .controlSize(.small)
                Button("中止") {
                    model.cancelScan()
                }
                .disabled(model.state == .cancelling)
            } else if model.session != nil {
                Button("再スキャン") {
                    Task { await model.rescan() }
                }
                .disabled(!model.canRescan)
                .help("選んだ対象全体を走査し直し、結果を置き換えます")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 走査中は通知がなくても経過時間を進める。
private struct ElapsedText: View {
    let progress: ScanProgress

    var body: some View {
        if progress.finishedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("経過 \(DisplayText.elapsed(context.date.timeIntervalSince(progress.startedAt)))")
            }
        } else {
            Text("所要 \(DisplayText.elapsed(progress.elapsed))")
        }
    }
}
