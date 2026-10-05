import AppKit
import Foundation
import Observation
import DiskUsageCore

enum ResultTab: String, CaseIterable, Identifiable {
    case list
    case treemap
    case largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "一覧"
        case .treemap: return "Treemap"
        case .largeFiles: return "大きなファイル"
        }
    }
}

struct UserMessage: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

/// Treemap に渡す直下項目。上位だけを持ち、残りは件数と既知合計にまとめる。
struct TreemapSnapshot: Equatable, Sendable {
    let directoryID: ItemID
    let items: [ScanItem]
    let remainderCount: Int
    let remainderBytes: Int64
}

/// UI 操作と ScanCoordinator・ItemActionService をつなぐ。
///
/// 公開状態は MainActor で更新する。ストアへの問い合わせは MainActor 外で行い、
/// スキャン ID と問い合わせ条件が変わっていない場合だけ結果を反映する。
@MainActor
@Observable
final class ScanViewModel {
    nonisolated static let pageSize = 200
    nonisolated static let treemapLimit = 400

    @ObservationIgnored private let coordinator: ScanCoordinator
    @ObservationIgnored private let actions: ItemActionService
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false

    // MARK: 開始画面

    private(set) var volumes: [VolumeEntry] = []
    var selectedTarget: ScanTarget?

    // MARK: スキャン

    private(set) var session: ScanSession?
    private(set) var scannedTarget: ScanTarget?
    private(set) var progress: ScanProgress?
    private(set) var result: ScanResult?
    /// 前のスキャンのキャンセル完了を待っている
    private(set) var isPreparingScan = false
    private(set) var capacity: VolumeCapacity?

    // MARK: 結果の表示

    var tab: ResultTab = .list
    private(set) var directoryID: ItemID?
    private(set) var directory: ScanItem?
    private(set) var breadcrumbs: [ScanItem] = []
    private(set) var children: ItemPage?
    private(set) var childrenOffset = 0
    private(set) var treemap: TreemapSnapshot?
    private(set) var largeFiles: ItemPage?
    private(set) var largeFilesOffset = 0

    var selectionID: ItemID? {
        didSet {
            if selectionID != oldValue {
                refresh()
            }
        }
    }
    private(set) var selectedItem: ScanItem?
    private(set) var selectedPath: String?

    // MARK: ファイル操作

    var pendingTrash: TrashCandidate?
    var message: UserMessage?
    private(set) var isTrashing = false
    private(set) var movedItems: Set<ItemID> = []

    init(coordinator: ScanCoordinator = ScanCoordinator(), actions: ItemActionService? = nil) {
        self.coordinator = coordinator
        self.actions = actions ?? ItemActionService(coordinator: coordinator)
    }

    // MARK: - 状態の要約

    var state: ScanState? { progress?.state ?? result?.state }

    var isScanActive: Bool {
        guard let state else { return false }
        return !state.isTerminal
    }

    var canStartScan: Bool {
        selectedTarget != nil && !isPreparingScan
    }

    // MARK: - 開始・キャンセル・再スキャン

    func loadVolumes() {
        volumes = VolumeEntry.mountedVolumes()
        if selectedTarget == nil {
            selectedTarget = volumes.first.map(ScanTarget.volume)
        }
    }

    func chooseFolder(_ url: URL) {
        selectedTarget = .folder(url)
    }

    /// 対象を走査する。実行中のスキャンがあれば、キャンセル完了を待ってから始める。
    func startScan(_ target: ScanTarget? = nil) async {
        guard let target = target ?? selectedTarget, !isPreparingScan else { return }
        isPreparingScan = true
        defer { isPreparingScan = false }

        if let current = session, !current.currentState.isTerminal {
            current.cancel()
            _ = await current.waitUntilFinished()
        }
        guard let scope = ScopeResolver.scope(forPath: target.path, isVolume: target.isVolume) else {
            message = UserMessage(title: "スキャンを開始できません", detail: "「\(target.displayName)」の場所を確認できませんでした。")
            return
        }
        do {
            let session = try coordinator.start(scope: scope)
            attach(session, target: target)
        } catch {
            message = UserMessage(title: "スキャンを開始できません", detail: "前のスキャンの停止を待っています。少し待ってからもう一度試してください。")
        }
    }

    func cancelScan() {
        session?.cancel()
        if let session {
            progress = session.progress
        }
    }

    func rescan() async {
        guard let target = scannedTarget else { return }
        await startScan(target)
    }

    private func attach(_ session: ScanSession, target: ScanTarget) {
        updatesTask?.cancel()
        self.session = session
        scannedTarget = target
        selectedTarget = target
        progress = session.progress
        result = session.result
        capacity = VolumeCapacity.fetch(forPath: session.scope.rootPath)
        directoryID = ItemID(0)
        directory = nil
        breadcrumbs = []
        children = nil
        childrenOffset = 0
        treemap = nil
        largeFiles = nil
        largeFilesOffset = 0
        selectedItem = nil
        selectedPath = nil
        movedItems = []
        pendingTrash = nil
        selectionID = nil
        refresh()

        updatesTask = Task { [weak self] in
            for await progress in session.makeUpdates() {
                guard let self, self.session === session else { return }
                self.progress = progress
                self.result = session.result
                self.refresh()
            }
        }
    }

    // MARK: - ナビゲーション

    func open(_ id: ItemID) {
        guard let session, let item = session.store.item(id), item.kind == .directory else { return }
        directoryID = id
        childrenOffset = 0
        refresh()
    }

    func goUp() {
        guard let parent = directory?.parentID else { return }
        let previous = directoryID
        open(parent)
        selectionID = previous
    }

    /// 一覧の行やタイルを確定操作したとき。フォルダなら開き、それ以外は選択する。
    func activate(_ item: ScanItem) {
        if item.kind == .directory, item.traversalState != .excluded {
            open(item.id)
        } else {
            selectionID = item.id
        }
    }

    func showChildrenPage(offset: Int) {
        childrenOffset = max(0, offset)
        refresh()
    }

    func showLargeFilesPage(offset: Int) {
        largeFilesOffset = max(0, offset)
        refresh()
    }

    /// Treemap の「その他」から一覧へ移り、まとめられた項目の先頭を表示する。
    func showOthersInList(firstIndex: Int) {
        tab = .list
        childrenOffset = (firstIndex / Self.pageSize) * Self.pageSize
        refresh()
    }

    // MARK: - Finder とゴミ箱

    var canRevealSelection: Bool {
        guard let selectionID, selectedPath != nil else { return false }
        return !movedItems.contains(selectionID)
    }

    func revealSelectionInFinder() {
        guard canRevealSelection, let path = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// ゴミ箱ボタンを有効にするか。理由はヘルプとして表示する。
    var trashAvailability: Result<TrashCandidate, TrashBlockReason>? {
        guard let session, let selectionID, !isTrashing else { return nil }
        return actions.candidate(for: selectionID, in: session)
    }

    func requestTrash() {
        guard let availability = trashAvailability else { return }
        switch availability {
        case .success(let candidate):
            pendingTrash = candidate
        case .failure(let reason):
            message = UserMessage(title: "ゴミ箱へ移動できません", detail: reason.message)
        }
    }

    func confirmTrash() async {
        guard let candidate = pendingTrash, let session, session.scanID == candidate.scanID else {
            pendingTrash = nil
            return
        }
        pendingTrash = nil
        isTrashing = true
        let actions = self.actions
        let outcome = await Task.detached(priority: .userInitiated) {
            actions.moveToTrash(candidate, in: session)
        }.value
        isTrashing = false
        guard self.session === session else { return }
        switch outcome {
        case .success:
            movedItems.insert(candidate.itemID)
            result = session.result
            // 空き容量は OS から取り直す。移動したサイズを解放量として扱わない。
            capacity = VolumeCapacity.fetch(forPath: session.scope.rootPath)
            volumes = VolumeEntry.mountedVolumes()
        case .failure(let failure):
            message = UserMessage(title: "ゴミ箱へ移動できませんでした", detail: failure.message)
        }
        refresh()
    }

    // MARK: - 問い合わせ

    private struct Query: Equatable, Sendable {
        let scanID: ScanID
        let directoryID: ItemID
        let childrenOffset: Int
        let largeFilesOffset: Int
        let selectionID: ItemID?
    }

    private struct Snapshot: Sendable {
        let directory: ScanItem?
        let breadcrumbs: [ScanItem]
        let children: ItemPage
        let treemap: TreemapSnapshot
        let largeFiles: ItemPage
        let selectedItem: ScanItem?
        let selectedPath: String?
    }

    private var currentQuery: Query? {
        guard let session, let directoryID else { return nil }
        return Query(
            scanID: session.scanID, directoryID: directoryID,
            childrenOffset: childrenOffset, largeFilesOffset: largeFilesOffset, selectionID: selectionID
        )
    }

    /// 表示中の範囲を問い合わせ直す。実行中の問い合わせがあれば、終わってから一度だけやり直す。
    func refresh() {
        guard let session, let query = currentQuery else { return }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        let store = session.store
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.run(query, store: store)
            }.value
            guard let self else { return }
            self.refreshTask = nil
            // 旧スキャン・古い条件の応答で新しい画面を上書きしない
            if self.currentQuery == query {
                self.apply(snapshot)
            } else {
                self.refreshPending = true
            }
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        directory = snapshot.directory
        breadcrumbs = snapshot.breadcrumbs
        children = snapshot.children
        treemap = snapshot.treemap
        largeFiles = snapshot.largeFiles
        selectedItem = snapshot.selectedItem
        selectedPath = snapshot.selectedPath
    }

    nonisolated private static func run(_ query: Query, store: ScanStore) -> Snapshot {
        let directory = store.item(query.directoryID)
        let breadcrumbs = store.ancestry(of: query.directoryID).compactMap { store.item($0) }
        let children = store.children(of: query.directoryID, offset: query.childrenOffset, limit: pageSize)
        let treemapData = store.childrenForTreemap(of: query.directoryID, limit: treemapLimit)
        let largeFiles = store.largestFiles(offset: query.largeFilesOffset, limit: pageSize)
        let selected = query.selectionID.flatMap { store.item($0) }
        let selectedPath = query.selectionID.flatMap { store.path(of: $0) }
        return Snapshot(
            directory: directory,
            breadcrumbs: breadcrumbs,
            children: children,
            treemap: TreemapSnapshot(
                directoryID: query.directoryID,
                items: treemapData.page.items,
                remainderCount: treemapData.remainderCount,
                remainderBytes: treemapData.remainderKnownBytes
            ),
            largeFiles: largeFiles,
            selectedItem: selected,
            selectedPath: selectedPath
        )
    }
}
