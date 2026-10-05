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
                        Text("走査項目の集計: \(DisplayText.size(of: root))")
                            .font(.callout)
                    }
                }
                Spacer(minLength: 8)
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
                .lineLimit(1)
            }
            // 案内は横幅いっぱいの行にして、狭いウィンドウでも縦に伸びすぎないようにする
            if model.state == .failed, let reason = model.result?.failureDescription {
                Banner(text: "スキャンできませんでした: \(reason)。対象を選び直すか、アクセス権を確認してください。", color: .red)
                if model.result?.counts.problemItems ?? 0 > 0 {
                    PermissionGuidance()
                }
            } else if let problems = model.progress?.counts.problemItems, problems > 0 {
                Banner(text: "情報を取得できなかった場所があります（アクセス拒否・読み取りエラー・クラウド上だけの項目など）。画面下の「情報を取得できなかった項目」から確認できます。", color: .orange)
            }
            if model.result?.isStale == true {
                Banner(text: "ゴミ箱へ移動した項目があります。表示中の容量は移動前のものです。最新の容量は再スキャンで確認してください。", color: .orange)
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
            Text("走査項目の集計はボリュームの使用量と一致しないことがあります")
                .font(.headline)
            Text("・読めなかった場所や、除外した場所（別ボリューム・別経路など）は集計に含まれません。")
            Text("・APFS のクローンやハードリンクは共有ブロックを区別せず、パスごとに数えます。")
            Text("・スナップショットや purgeable 領域、システム領域の一部は走査で見えません。")
            Text("・割り当て済みサイズは、その項目だけが占める容量とは限らず、ゴミ箱へ移して空き容量が同じだけ増えるとも限りません。")
            Text("・ボリューム容量は macOS が報告する値で、取得時刻の時点のものです。")
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
            .help("親フォルダへ（⌘↑）")
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
            Text("ファイル \(counts.files.formatted()) 件")
            Text("フォルダ \(counts.directories.formatted()) 件")
            Button("情報を取得できなかった項目 \(counts.problemItems.formatted()) 件") {
                sheet = .problems
            }
            .buttonStyle(.link)
            .foregroundStyle(counts.problemItems > 0 ? .orange : .secondary)
            .disabled(counts.problemItems == 0)
            .help("アクセス拒否・読み取りエラー・クラウド上のみなど、情報を取得できなかった項目。クリックで一覧を表示")
            Button("除外 \(counts.excludedItems.formatted()) 件") {
                sheet = .excluded
            }
            .buttonStyle(.link)
            .disabled(counts.excludedItems == 0)
            .help("別ボリュームや別経路など、二重に数えないため走査しなかった場所。クリックで一覧を表示")
        }
    }

    @ViewBuilder
    private var times: some View {
        if let progress = model.progress {
            ElapsedText(progress: progress)
            if let finished = progress.finishedAt {
                Text("\(DisplayText.time(progress.startedAt))〜\(DisplayText.time(finished))")
                    .foregroundStyle(.secondary)
            } else {
                Text("開始 \(DisplayText.time(progress.startedAt))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
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
