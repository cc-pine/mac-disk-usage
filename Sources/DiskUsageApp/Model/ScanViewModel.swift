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
/// 公開状態は MainActor で更新する。ストアへの問い合わせとゴミ箱移動の可否判定は MainActor 外で行い、
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
    private(set) var childrenOffset = 0
    private(set) var largeFilesOffset = 0
    var selectionID: ItemID? {
        didSet {
            if selectionID != oldValue {
                refresh()
            }
        }
    }
    /// 最後に反映した問い合わせ結果。ID が現在の条件と一致する部分だけを公開する。
    private var snapshot: Snapshot?

    // MARK: ファイル操作

    var pendingTrash: TrashCandidate?
    var isTrashDialogPresented = false
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
        selectedTarget != nil && !isPreparingScan && !isTrashing
    }

    var canRescan: Bool {
        scannedTarget != nil && !isScanActive && !isPreparingScan && !isTrashing
    }

    // MARK: - 問い合わせ結果（現在の条件と一致するものだけ）

    var directory: ScanItem? {
        guard let snapshot, snapshot.query.directoryID == directoryID else { return nil }
        return snapshot.directory
    }

    var breadcrumbs: [ScanItem] {
        guard let snapshot, snapshot.query.directoryID == directoryID else { return [] }
        return snapshot.breadcrumbs
    }

    var scanRoot: ScanItem? {
        snapshot?.breadcrumbs.first
    }

    var children: ItemPage? {
        guard let snapshot, snapshot.query.directoryID == directoryID, snapshot.query.childrenOffset == childrenOffset else { return nil }
        return snapshot.children
    }

    var treemap: TreemapSnapshot? {
        guard let snapshot, snapshot.query.directoryID == directoryID else { return nil }
        return snapshot.treemap
    }

    var largeFiles: ItemPage? {
        guard let snapshot, snapshot.query.largeFilesOffset == largeFilesOffset else { return nil }
        return snapshot.largeFiles
    }

    var selectedItem: ScanItem? {
        guard let snapshot, let selectionID, snapshot.query.selectionID == selectionID else { return nil }
        return snapshot.selectedItem
    }

    var selectedPath: String? {
        guard selectedItem != nil else { return nil }
        return snapshot?.selectedPath
    }

    /// ゴミ箱ボタンを有効にするか。理由は詳細パネルに表示する。
    var trashAvailability: Result<TrashCandidate, TrashBlockReason>? {
        guard !isTrashing, selectedItem != nil else { return nil }
        return snapshot?.trashAvailability
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
        guard let target = target ?? selectedTarget, !isPreparingScan, !isTrashing else { return }
        isPreparingScan = true
        defer { isPreparingScan = false }

        if let current = session, !current.currentState.isTerminal {
            current.cancel()
            progress = current.progress
            _ = await current.waitUntilFinished()
        }
        guard let scope = ScopeResolver.scope(forPath: target.path, isVolume: target.isVolume) else {
            message = UserMessage(title: "スキャンを開始できません", detail: "「\(target.displayName)」の場所を確認できませんでした。")
            return
        }
        do {
            let session = try coordinator.start(scope: scope)
            attach(session, target: target)
        } catch ScanCoordinatorError.fileOperationInProgress {
            message = UserMessage(title: "スキャンを開始できません", detail: "ゴミ箱への移動が終わってから、もう一度試してください。")
        } catch {
            message = UserMessage(title: "スキャンを開始できません", detail: "前のスキャンの停止を待っています。少し待ってからもう一度試してください。")
        }
    }

    func cancelScan() {
        guard let session else { return }
        session.cancel()
        progress = session.progress
    }

    func rescan() async {
        guard let target = scannedTarget, canRescan else { return }
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
        childrenOffset = 0
        largeFilesOffset = 0
        snapshot = nil
        movedItems = []
        pendingTrash = nil
        isTrashDialogPresented = false
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

    var canGoUp: Bool {
        guard let session, let directoryID else { return false }
        return session.store.item(directoryID)?.parentID != nil
    }

    func goUp() {
        // 問い合わせ結果の反映を待たず、ストアから現在のフォルダの親を引く
        guard let session, let current = directoryID, let parent = session.store.item(current)?.parentID else { return }
        open(parent)
        selectionID = current
    }

    /// 一覧の行やタイルを確定操作したとき。フォルダなら開き、それ以外は選択する。
    func activate(_ item: ScanItem) {
        if item.kind == .directory, item.traversalState != .excluded {
            open(item.id)
        } else {
            selectionID = item.id
        }
    }

    /// 選択中の項目を開く（キーボード操作用）。
    func openSelection() {
        guard let session, let selectionID, let item = session.store.item(selectionID) else { return }
        activate(item)
    }

    func showChildrenPage(offset: Int) {
        childrenOffset = max(0, offset)
        refresh()
    }

    func showLargeFilesPage(offset: Int) {
        largeFilesOffset = max(0, offset)
        refresh()
    }

    /// Treemap の「その他」から一覧へ移り、まとめられた項目の先頭を表示・選択する。
    func showOthersInList(firstIndex: Int) {
        guard let session, let directoryID else { return }
        tab = .list
        childrenOffset = (firstIndex / Self.pageSize) * Self.pageSize
        refresh()
        let store = session.store
        Task { [weak self] in
            let first = await Task.detached(priority: .userInitiated) {
                store.children(of: directoryID, offset: firstIndex, limit: 1).items.first?.id
            }.value
            guard let self, self.session === session, self.directoryID == directoryID, let first else { return }
            self.selectionID = first
        }
    }

    // MARK: - Finder とゴミ箱

    var canRevealSelection: Bool {
        guard let item = selectedItem, selectedPath != nil else { return false }
        return !movedItems.contains(item.id)
    }

    func revealSelectionInFinder() {
        guard canRevealSelection, let path = selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 確認ダイアログを開く前に、最新の状態で可否を確かめる。
    func requestTrash() {
        guard let session, let item = selectedItem, !isTrashing else { return }
        switch actions.candidate(for: item.id, in: session) {
        case .success(let candidate):
            pendingTrash = candidate
            isTrashDialogPresented = true
        case .failure(let reason):
            message = UserMessage(title: "ゴミ箱へ移動できません", detail: reason.message)
        }
    }

    func cancelTrash() {
        pendingTrash = nil
        isTrashDialogPresented = false
    }

    /// 確認ダイアログで示した対象を移動する。対象はダイアログが表示していた値を受け取る。
    func confirmTrash(_ candidate: TrashCandidate) async {
        pendingTrash = nil
        isTrashDialogPresented = false
        guard let session, session.scanID == candidate.scanID, !isTrashing else { return }
        isTrashing = true
        let actions = self.actions
        let outcome = await Task.detached(priority: .userInitiated) {
            actions.moveToTrash(candidate, in: session)
        }.value
        isTrashing = false
        guard self.session === session else { return }

        // 取り違えの警告を含め、実際に移動したかどうかで表示を更新する
        result = session.result
        if actions.isMoved(candidate.itemID, in: session) {
            movedItems.insert(candidate.itemID)
            // 空き容量は OS から取り直す。移動したサイズを解放量として扱わない。
            capacity = VolumeCapacity.fetch(forPath: session.scope.rootPath)
            volumes = VolumeEntry.mountedVolumes()
        }
        if case .failure(let failure) = outcome {
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
        /// 版が進んだら同じ条件でも問い合わせ直す
        let revision: Int
    }

    private struct Snapshot: Sendable {
        let query: Query
        let directory: ScanItem?
        let breadcrumbs: [ScanItem]
        let children: ItemPage
        let treemap: TreemapSnapshot
        let largeFiles: ItemPage
        let selectedItem: ScanItem?
        let selectedPath: String?
        let trashAvailability: Result<TrashCandidate, TrashBlockReason>?
    }

    private var currentQuery: Query? {
        guard let session, let directoryID else { return nil }
        return Query(
            scanID: session.scanID, directoryID: directoryID,
            childrenOffset: childrenOffset, largeFilesOffset: largeFilesOffset, selectionID: selectionID,
            revision: progress?.revision ?? 0
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
        let actions = self.actions
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                ScanViewModel.run(query, store: store, session: session, actions: actions)
            }.value
            guard let self else { return }
            self.refreshTask = nil
            // 旧スキャンの応答は捨てる。条件が変わっていても、一致する部分だけは表示に使える
            if self.session?.scanID == query.scanID {
                self.snapshot = snapshot
            }
            if self.currentQuery != query {
                self.refreshPending = true
            }
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    nonisolated private static func run(_ query: Query, store: ScanStore, session: ScanSession, actions: ItemActionService) -> Snapshot {
        let directory = store.item(query.directoryID)
        let breadcrumbs = store.ancestry(of: query.directoryID).compactMap { store.item($0) }
        let children = store.children(of: query.directoryID, offset: query.childrenOffset, limit: pageSize)
        let treemapData = store.childrenForTreemap(of: query.directoryID, limit: treemapLimit)
        let largeFiles = store.largestFiles(offset: query.largeFilesOffset, limit: pageSize)
        let selected = query.selectionID.flatMap { store.item($0) }
        let selectedPath = query.selectionID.flatMap { store.path(of: $0) }
        let trashAvailability = query.selectionID.map { actions.candidate(for: $0, in: session) }
        return Snapshot(
            query: query,
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
            selectedPath: selectedPath,
            trashAvailability: trashAvailability
        )
    }
}
