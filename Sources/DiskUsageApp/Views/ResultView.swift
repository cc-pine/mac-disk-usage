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
            Picker(L10n.viewPicker, selection: $model.tab) {
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
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusFooter()
        }
    }
}

private struct ResultHeader: View {
    @Environment(ScanViewModel.self) private var model
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.scannedTarget?.displayName ?? "")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(DisplayText.state(model.state, isStale: model.result?.isStale ?? false))
                        .foregroundStyle(stateColor)
                    if let root = model.scanRoot {
                        Text(L10n.scanTotal(DisplayText.size(of: root)))
                            .font(.callout)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let capacity = model.capacity, let total = capacity.totalBytes {
                        Text(L10n.volumeUsage(used: capacity.usedBytes.map { ByteFormatting.string($0) }, total: ByteFormatting.string(total)))
                        Text(L10n.volumeAvailable(ByteFormatting.string(capacity.availableBytes), time: DisplayText.time(capacity.fetchedAt)))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.volumeCapacityUnavailable)
                            .foregroundStyle(.secondary)
                    }
                    Button(L10n.explainDifference) {
                        showsExplanation = true
                    }
                    .buttonStyle(.link)
                    .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
                        AggregationExplanation()
                    }
                }
                .font(.callout)
                .lineLimit(1)
            }
            // 案内は横幅いっぱいの行にして、狭いウィンドウでも縦に伸びすぎないようにする
            if model.state == .failed, let reason = model.result?.failureDescription {
                Banner(text: L10n.scanFailed(reason), color: .red)
                if model.result?.counts.problemItems ?? 0 > 0 {
                    PermissionGuidance()
                }
            } else {
                if model.result?.wasForceStopped == true {
                    Banner(text: L10n.forceStoppedBanner, color: .orange)
                }
                // 強制中止した場合も、取得できなかった情報があることは併せて示す
                if let problems = model.progress?.counts.problemItems, problems > 0 {
                    Banner(text: L10n.missingInfoBanner, color: .orange)
                }
            }
            if model.result?.isStale == true {
                Banner(text: L10n.staleBanner, color: .orange)
            }
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

private struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 走査集計とボリューム使用量が一致しない理由の説明。
struct AggregationExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.explanationTitle)
                .font(.headline)
            Text(L10n.explanationUnread)
            Text(L10n.explanationClones)
            Text(L10n.explanationSnapshots)
            Text(L10n.explanationAllocated)
            Text(L10n.explanationCapacity)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
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
            .help(L10n.parentFolderHelp)
            .disabled(!model.canGoUp)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(model.displayedBreadcrumbs.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        // ルートはヘッダーと同じ名前（ボリューム名・表示名）で示す
                        Button(index == 0 ? (model.scannedTarget?.displayName ?? item.name) : item.name) {
                            model.open(item)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(item.id == model.directoryID ? .semibold : .regular)
                    }
                }
            }
            if model.isLoadingView {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct StatusFooter: View {
    @Environment(ScanViewModel.self) private var model
    @State private var sheet: ItemCategory?

    var body: some View {
        content
            .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
                if let sheet, let session = model.session {
                    LocationsSheet(category: sheet, session: session, revision: model.progress?.revision ?? 0)
                }
            }
            .onChange(of: model.session?.scanID) {
                // 別のスキャンに切り替わったら、旧結果の一覧を閉じる
                sheet = nil
            }
    }

    /// 横幅が足りないときは件数と時刻を2行に分ける。
    private var content: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                counts
                times
                Spacer(minLength: 8)
                controls
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    counts
                }
                HStack(spacing: 12) {
                    times
                    Spacer(minLength: 8)
                    controls
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var counts: some View {
        if let counts = model.progress?.counts {
            Text(L10n.filesCount(counts.files))
            Text(L10n.foldersCount(counts.directories))
            Button(L10n.missingCount(counts.problemItems)) {
                sheet = .problems
            }
            .buttonStyle(.link)
            .foregroundStyle(counts.problemItems > 0 ? .orange : .secondary)
            .disabled(counts.problemItems == 0)
            .help(L10n.missingHelp)
            Button(L10n.excludedCount(counts.excludedItems)) {
                sheet = .excluded
            }
            .buttonStyle(.link)
            .disabled(counts.excludedItems == 0)
            .help(L10n.excludedHelp)
        }
    }

    @ViewBuilder
    private var times: some View {
        if let progress = model.progress {
            ElapsedText(progress: progress)
            if let finished = progress.finishedAt {
                Text(L10n.timeRange(DisplayText.time(progress.startedAt), DisplayText.time(finished)))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.started(DisplayText.time(progress.startedAt)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if model.isScanActive {
            ProgressView()
                .controlSize(.small)
            if model.state == .cancelling {
                ForceStopButton(requestedAt: model.cancelRequestedAt) {
                    model.forceStopScan()
                }
            } else {
                Button(L10n.stop) {
                    model.cancelScan()
                }
            }
        } else if model.session != nil {
            Button(L10n.rescan) {
                Task { await model.rescan() }
            }
            .disabled(!model.canRescan)
            .help(L10n.rescanHelp)
        }
    }
}

/// 走査中は通知がなくても経過時間を進める。
private struct ElapsedText: View {
    let progress: ScanProgress

    var body: some View {
        if progress.finishedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(L10n.elapsed(DisplayText.elapsed(context.date.timeIntervalSince(progress.startedAt))))
            }
        } else {
            Text(L10n.took(DisplayText.elapsed(progress.elapsed)))
        }
    }
}

/// 停止待ちが続いたときだけ出す強制中止ボタン。自動では切り離さず、利用者が選んだときだけ中止を確定する。
struct ForceStopButton: View {
    /// 停止待ちがこの秒数続いたらボタンを出す
    static let delay: TimeInterval = 3

    let requestedAt: Date?
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let waited = requestedAt.map { context.date.timeIntervalSince($0) } ?? 0
            if waited >= Self.delay {
                Button(L10n.forceStop, action: action)
                    .help(L10n.forceStopHelp)
            } else {
                Text(L10n.stopping)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
