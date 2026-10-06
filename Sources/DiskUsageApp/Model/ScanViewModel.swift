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
        case .list: return L10n.tabList
        case .treemap: return L10n.tabTreemap
        case .largeFiles: return L10n.tabLargeFiles
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
    /// 実行中の問い合わせが対象とするスキャン。別のスキャンの問い合わせは待たない
    @ObservationIgnored private var refreshScanID: ScanID?
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

    /// 走査中に同じ対象を選んだままのときは、黙ってやり直さないよう開始できなくする。
    var canStartScan: Bool {
        guard let selectedTarget, !isPreparingScan, !isTrashing, !isTrashDialogPresented else { return false }
        return !(isScanActive && selectedTarget == scannedTarget)
    }

    var canRescan: Bool {
        scannedTarget != nil && !isScanActive && !isPreparingScan && !isTrashing
    }

    // MARK: - 問い合わせ結果

    /// 表示中の一覧・Treemap が、現在の条件の結果をまだ受け取っていないか。
    /// 読み込み中も前の結果を表示したまま（表やフォーカスを壊さず）、この値で読み込み中を示す。
    var isLoadingView: Bool {
        guard let query = currentQuery else { return false }
        guard let snapshot else { return true }
        return snapshot.query.directoryID != query.directoryID
            || snapshot.query.childrenOffset != query.childrenOffset
            || snapshot.query.largeFilesOffset != query.largeFilesOffset
    }

    /// 現在のフォルダ。問い合わせ結果が現在のフォルダと一致する場合だけ返す。
    var directory: ScanItem? {
        guard let snapshot, snapshot.query.directoryID == directoryID else { return nil }
        return snapshot.directory
    }

    /// 現在のフォルダのパンくず。親への移動の判定に使うため、一致する場合だけ返す。
    var breadcrumbs: [ScanItem] {
        guard let snapshot, snapshot.query.directoryID == directoryID else { return [] }
        return snapshot.breadcrumbs
    }

    /// 表示用のパンくず。読み込み中は前のフォルダのものを表示し続ける。
    var displayedBreadcrumbs: [ScanItem] {
        snapshot?.breadcrumbs ?? []
    }

    var scanRoot: ScanItem? {
        snapshot?.breadcrumbs.first
    }

    var children: ItemPage? {
        snapshot?.children
    }

    var treemap: TreemapSnapshot? {
        snapshot?.treemap
    }

    var largeFiles: ItemPage? {
        snapshot?.largeFiles
    }

    /// 大きなファイル一覧の各行の親フォルダのパス
    var largeFileFolders: [ItemID: String] {
        snapshot?.largeFileFolders ?? [:]
    }

    /// 選択項目。問い合わせ結果が届くまでは、表示中の行のデータを使って詳細パネルを空にしない。
    var selectedItem: ScanItem? {
        guard let selectionID else { return nil }
        if let snapshot, snapshot.query.selectionID == selectionID {
            return snapshot.selectedItem
        }
        let visible = (children?.items ?? []) + (largeFiles?.items ?? []) + (treemap?.items ?? [])
        return visible.first { $0.id == selectionID }
    }

    var selectedPath: String? {
        guard let snapshot, let selectionID, snapshot.query.selectionID == selectionID else { return nil }
        return snapshot.selectedPath
    }

    /// ゴミ箱ボタンを有効にするか。理由は詳細パネルに表示する。最新の判定が届くまでは nil。
    var trashAvailability: Result<TrashCandidate, TrashBlockReason>? {
        guard !isTrashing, let snapshot, let selectionID, snapshot.query.selectionID == selectionID else { return nil }
        return snapshot.trashAvailability
    }

    // MARK: - 開始・キャンセル・再スキャン

    /// 選んだフォルダ。サイドバーで別の対象を選んでも一覧から消さない。
    private(set) var chosenFolder: URL?
    /// 走査中に別の対象を選んで開始しようとしたときの確認
    var isSwitchConfirmationPresented = false
    @ObservationIgnored private var isLoadingVolumes = false

    /// ボリュームの容量問い合わせは応答しないネットワークマウントなどで待つことがあるため、
    /// MainActor の外で行う。
    func loadVolumes() {
        guard !isLoadingVolumes else { return }
        isLoadingVolumes = true
        Task { [weak self] in
            let volumes = await Task.detached(priority: .userInitiated) {
                VolumeEntry.mountedVolumes()
            }.value
            guard let self else { return }
            self.isLoadingVolumes = false
            self.volumes = volumes
            if self.selectedTarget == nil {
                self.selectedTarget = volumes.first.map(ScanTarget.volume)
            }
        }
    }

    func chooseFolder(_ url: URL) {
        chosenFolder = url
        selectedTarget = .folder(url)
    }

    /// 開始操作。走査中に別の対象を選んでいる場合は、中止してよいかを確かめる。
    func requestStartScan() {
        guard canStartScan else { return }
        if isScanActive {
            isSwitchConfirmationPresented = true
        } else {
            Task { await startScan() }
        }
    }

    /// 対象を走査する。実行中のスキャンがあれば、キャンセル完了を待ってから始める。
    func startScan(_ target: ScanTarget? = nil) async {
        guard let target = target ?? selectedTarget, !isPreparingScan, !isTrashing else { return }
        isPreparingScan = true
        defer { isPreparingScan = false }

        if let current = session, !current.currentState.isTerminal {
            if current.currentState == .scanning {
                cancelRequestedAt = Date()
            }
            current.cancel()
            progress = current.progress
            _ = await current.waitUntilFinished()
        }
        // realpath と lstat を伴うため MainActor の外で解決する
        let path = target.path
        let isVolume = target.isVolume
        let resolved = await Task.detached(priority: .userInitiated) {
            ScopeResolver.scope(forPath: path, isVolume: isVolume)
        }.value
        guard let scope = resolved else {
            message = UserMessage(title: L10n.cannotStartScan, detail: L10n.targetNotFound(target.displayName))
            return
        }
        do {
            let session = try coordinator.start(scope: scope)
            attach(session, target: target)
        } catch ScanCoordinatorError.fileOperationInProgress {
            message = UserMessage(title: L10n.cannotStartScan, detail: L10n.waitForTrash)
        } catch {
            message = UserMessage(title: L10n.cannotStartScan, detail: L10n.previousScanStopping)
        }
    }

    /// キャンセルを要求した時刻。停止待ちが長引いたら強制中止を出すために使う
    private(set) var cancelRequestedAt: Date?

    func cancelScan() {
        guard let session else { return }
        if session.currentState == .scanning {
            cancelRequestedAt = Date()
        }
        session.cancel()
        progress = session.progress
    }

    /// 停止待ち（OS 呼び出しが戻らない）の間だけ、利用者の明示操作で中止を確定する。
    func forceStopScan() {
        guard let session, session.currentState == .cancelling else { return }
        session.forceStop()
        progress = session.progress
        result = session.result
    }

    func rescan() async {
        guard let target = scannedTarget, canRescan else { return }
        await startScan(target)
    }

    /// ボリューム容量を OS から取り直す。応答しないマウントで待たないよう MainActor の外で行う。
    private func refreshCapacity(for session: ScanSession) {
        let rootPath = session.scope.rootPath
        Task { [weak self] in
            let capacity = await Task.detached(priority: .utility) {
                VolumeCapacity.fetch(forPath: rootPath)
            }.value
            guard let self, self.session === session else { return }
            self.capacity = capacity
        }
    }

    private func attach(_ session: ScanSession, target: ScanTarget) {
        updatesTask?.cancel()
        self.session = session
        scannedTarget = target
        selectedTarget = target
        progress = session.progress
        result = session.result
        capacity = nil
        refreshCapacity(for: session)
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

    /// フォルダを開く。項目は表示中の行やパンくずから受け取り、MainActor でストアを引かない。
    func open(_ item: ScanItem) {
        guard item.kind == .directory, item.traversalState != .excluded else { return }
        directoryID = item.id
        childrenOffset = 0
        refresh()
    }

    /// ビューの描画中に評価されるため、ストアのロックを取らず問い合わせ結果のパンくずから判定する。
    /// 大きなファイル一覧では表示中のフォルダが見えないため、親への移動はしない。
    var canGoUp: Bool {
        tab != .largeFiles && breadcrumbs.count > 1
    }

    /// 親フォルダへ移り、元のフォルダを選択したうえで、その行が見えるページを表示する。
    func goUp() {
        // パンくずは現在のフォルダと一致する場合だけ返るので、表示より古い親へ移ることはない
        let trail = breadcrumbs
        guard canGoUp, let current = directoryID, let session else { return }
        let parent = trail[trail.count - 2].id
        directoryID = parent
        childrenOffset = 0
        selectionID = current
        refresh()
        reveal(current, in: parent, session: session)
    }

    /// 一覧の行やタイルを確定操作したとき。フォルダなら開き、それ以外は選択する。
    func activate(_ item: ScanItem) {
        if item.kind == .directory, item.traversalState != .excluded {
            open(item)
        } else {
            selectionID = item.id
        }
    }

    /// 選択中の項目を開く（キーボード操作用）。
    func openSelection() {
        guard let item = selectedItem else { return }
        activate(item)
    }

    /// 大きなファイル一覧で選んだファイルを、一覧タブの親フォルダ内で表示する。
    func showSelectionInFolder() {
        guard let session, let item = selectedItem, let parent = item.parentID else { return }
        tab = .list
        directoryID = parent
        childrenOffset = 0
        refresh()
        reveal(item.id, in: parent, session: session)
    }

    func showChildrenPage(offset: Int) {
        childrenOffset = max(0, offset)
        refresh()
    }

    func showLargeFilesPage(offset: Int) {
        largeFilesOffset = max(0, offset)
        refresh()
    }

    /// Treemap の「その他」から一覧へ移り、まとめられた項目の先頭を最初の行に表示して選択する。
    func showOthersInList(firstIndex: Int) {
        guard let session, let directoryID else { return }
        tab = .list
        childrenOffset = max(0, firstIndex)
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

    /// 子の並び順での位置を調べ、その行が先頭に来るページを表示する（表はスクロール位置を指定できないため）。
    private func reveal(_ child: ItemID, in parent: ItemID, session: ScanSession) {
        let store = session.store
        let startOffset = childrenOffset
        Task { [weak self] in
            let position = await Task.detached(priority: .userInitiated) {
                store.position(of: child, in: parent)
            }.value
            // 待っている間に利用者がページやフォルダを変えていたら上書きしない
            guard let self, self.session === session, self.directoryID == parent,
                  self.childrenOffset == startOffset, let position else { return }
            self.childrenOffset = position
            self.refresh()
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

    /// 確認ダイアログを開く前に、最新の状態で可否を確かめる。lstat などを伴うため MainActor の外で行う。
    func requestTrash() {
        guard let session, let item = selectedItem, !isTrashing else { return }
        let actions = self.actions
        let id = item.id
        Task { [weak self] in
            let availability = await Task.detached(priority: .userInitiated) {
                actions.candidate(for: id, in: session)
            }.value
            guard let self, self.session === session, self.selectionID == id else { return }
            switch availability {
            case .success(let candidate):
                self.pendingTrash = candidate
                self.isTrashDialogPresented = true
            case .failure(let reason):
                self.message = UserMessage(title: L10n.cannotMoveToTrash, detail: reason.message)
            }
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
        guard let session, session.scanID == candidate.scanID else {
            message = UserMessage(title: L10n.didNotMoveToTrash, detail: L10n.resultsReplaced)
            return
        }
        guard !isTrashing else { return }
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
            refreshCapacity(for: session)
            loadVolumes()
        }
        switch outcome {
        case .success(let moved) where !moved.isVerified:
            message = UserMessage(
                title: L10n.movedToTrashTitle,
                detail: L10n.movedButUnverified(DisplayText.visible(candidate.name))
            )
        case .success:
            break
        case .failure(.unexpectedItemMoved):
            // 何かが移動した可能性があるため「移動できなかった」とは書かない
            if case .failure(let failure) = outcome {
                message = UserMessage(title: L10n.checkTrashTitle, detail: failure.message)
            }
        case .failure(let failure):
            message = UserMessage(title: L10n.moveFailedTitle, detail: failure.message)
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
        let largeFileFolders: [ItemID: String]
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
        if refreshTask != nil, refreshScanID == query.scanID {
            refreshPending = true
            return
        }
        // 旧スキャンの問い合わせが残っていても待たない（その応答は scanID の照合で捨てる）
        refreshPending = false
        refreshScanID = query.scanID
        let store = session.store
        let actions = self.actions
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                ScanViewModel.run(query, store: store, session: session, actions: actions)
            }.value
            guard let self else { return }
            guard self.refreshScanID == query.scanID else { return }
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
        var largeFileFolders: [ItemID: String] = [:]
        for item in largeFiles.items {
            if let parent = item.parentID, let path = store.path(of: parent) {
                largeFileFolders[item.id] = path
            }
        }
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
            largeFileFolders: largeFileFolders,
            selectedItem: selected,
            selectedPath: selectedPath,
            trashAvailability: trashAvailability
        )
    }
}
