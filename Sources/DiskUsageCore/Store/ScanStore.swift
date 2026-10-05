import Foundation

/// 一覧の1ページ。`revision` は問い合わせ時点のストアの版。
public struct ItemPage: Sendable, Equatable {
    public let items: [ScanItem]
    public let offset: Int
    public let totalCount: Int
    public let revision: Int
    /// スキャン中で、上位の一部だけを返している場合 true
    public let isProvisional: Bool

    public init(items: [ScanItem], offset: Int, totalCount: Int, revision: Int, isProvisional: Bool) {
        self.items = items
        self.offset = offset
        self.totalCount = totalCount
        self.revision = revision
        self.isProvisional = isProvisional
    }
}

/// スキャン項目と親子索引、フォルダ集計、通常ファイル索引を保持する。
///
/// 書き込みはスキャンの保存処理だけが行い、UI からは問い合わせだけを行う。
/// 内部状態は1つのロックで守り、ノードごとの監視オブジェクトや全ツリーの複製を作らない。
public final class ScanStore: @unchecked Sendable {
    struct Node {
        var parent: Int32
        var name: String
        var kind: ItemKind
        var isPackage: Bool
        var logicalSize: Int64?
        var allocatedSize: Int64?
        var summary: SizeSummary
        var modifiedDate: Date?
        var createdDate: Date?
        var accessState: AccessState
        var traversalState: TraversalState
        var fileIdentity: FileIdentity?
        var exclusionReason: ExclusionReason?
        var errorDescription: String?
        /// 未完了の子ディレクトリ数
        var pendingChildDirectories: Int32 = 0
        var listingDone = false
        /// 配下に列挙エラー・キャンセルがあった
        var subtreeIncomplete = false
    }

    public let rootPath: String
    /// 大きなファイル一覧の暫定索引に保持する件数
    public let provisionalFileLimit: Int

    private let lock = NSLock()
    private var nodes: [Node] = []
    private var children: [[Int32]] = []
    private var counts = ScanCounts()
    private var revision = 0
    private var isFinalized = false
    private var topFiles: MinHeap
    private var fileIDs: [Int32] = []
    private var sortedFileIndex: [Int32]?
    private var provisionalCache: (revision: Int, ids: [Int32])?
    private var childrenCache: (directory: Int, revision: Int, ids: [Int32])?

    public init(rootPath: String, provisionalFileLimit: Int = 10_000) {
        self.rootPath = PathUtilities.normalize(rootPath)
        self.provisionalFileLimit = max(1, provisionalFileLimit)
        topFiles = MinHeap()
    }

    // MARK: - 書き込み

    /// バッチを保存し、集計を更新して版を進める。
    public func apply<S: Sequence>(_ records: S) where S.Element == ScanRecord {
        lock.lock()
        defer { lock.unlock() }
        // 確定後に遅れて届いたバッチは結果へ混ぜない
        guard !isFinalized else { return }
        var changed = false
        for record in records {
            switch record {
            case .item(let item):
                insert(item)
            case .directoryListed(let id, let outcome):
                markListed(id.index, outcome: outcome)
            }
            changed = true
        }
        if changed {
            revision += 1
        }
    }

    /// 走査を終えた時点で未完了のディレクトリを部分結果として確定する。
    /// - Returns: 未完了のディレクトリが残っていたか
    @discardableResult
    public func finalize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinalized else { return false }
        var hadUnvisited = false
        for index in nodes.indices where nodes[index].kind == .directory && nodes[index].traversalState == .pending {
            hadUnvisited = true
            nodes[index].traversalState = .partial
            if !nodes[index].listingDone {
                if nodes[index].accessState == .readable {
                    nodes[index].accessState = .notScanned
                }
                markUnvisited(index)
            }
        }
        isFinalized = true
        revision += 1
        return hadUnvisited
    }

    private func insert(_ item: DiscoveredItem) {
        let index = nodes.count
        precondition(item.id.index == index, "ID は発見順に連続して採番する")
        let parent = item.parentID.map { Int32($0.index) } ?? -1
        precondition(parent < Int32(index), "親は子より先に保存する")
        precondition(parent >= 0 || index == 0, "ルート以外は親を持つ")

        var summary = SizeSummary()
        var traversal: TraversalState
        var listingDone = false
        if item.exclusionReason != nil {
            traversal = .excluded
        } else {
            switch item.kind {
            case .directory:
                traversal = .pending
            case .file:
                traversal = .complete
                summary.knownLogicalBytes = item.logicalSize ?? 0
                summary.knownAllocatedBytes = item.allocatedSize ?? 0
                summary.unknownLogicalItems = item.logicalSize == nil ? 1 : 0
                summary.unknownAllocatedItems = item.allocatedSize == nil ? 1 : 0
            case .symbolicLink, .other:
                traversal = .complete
            }
        }
        if item.accessState != .readable, item.exclusionReason == nil {
            if item.kind == .directory {
                // 種類は分かったが中身を読めない（クラウド上だけのものを含む）。配下は列挙しない。
                summary.unreadableLocations = 1
                traversal = .partial
                listingDone = true
            } else if item.kind == .other {
                // メタデータを取得できなかった項目。サイズを 0 とみなさず不明として数える。
                summary.unknownLogicalItems = 1
                summary.unknownAllocatedItems = 1
            }
        }

        nodes.append(Node(
            parent: parent,
            name: item.name,
            kind: item.kind,
            isPackage: item.isPackage,
            logicalSize: item.kind == .file ? item.logicalSize : nil,
            allocatedSize: item.kind == .file ? item.allocatedSize : nil,
            summary: summary,
            modifiedDate: item.modifiedDate,
            createdDate: item.createdDate,
            accessState: item.accessState,
            traversalState: traversal,
            fileIdentity: item.fileIdentity,
            exclusionReason: item.exclusionReason,
            errorDescription: item.errorDescription,
            listingDone: listingDone
        ))
        children.append([])
        if parent >= 0 {
            children[Int(parent)].append(Int32(index))
            addToAncestors(of: Int(parent), summary)
            if traversal == .pending {
                nodes[Int(parent)].pendingChildDirectories += 1
            } else if traversal == .partial {
                nodes[Int(parent)].subtreeIncomplete = true
            }
        }

        updateCounts(for: item)
        if item.kind == .file, item.exclusionReason == nil {
            fileIDs.append(Int32(index))
            if item.allocatedSize != nil {
                offerTopFile(Int32(index))
            }
        }
    }

    private func updateCounts(for item: DiscoveredItem) {
        counts.enumeratedItems += 1
        let kindUnknown = item.kind == .other && item.accessState != .readable
        switch item.kind {
        case .file: counts.files += 1
        case .directory: counts.directories += 1
        case .symbolicLink: counts.symbolicLinks += 1
        case .other where !kindUnknown: counts.otherItems += 1
        case .other: break
        }
        if item.exclusionReason != nil {
            counts.excludedItems += 1
        } else if item.accessState != .readable {
            counts.problemItems += 1
        }
    }

    private func addToAncestors(of start: Int, _ delta: SizeSummary) {
        guard delta != SizeSummary() else { return }
        var cursor = Int32(start)
        while cursor >= 0 {
            let i = Int(cursor)
            nodes[i].summary.knownLogicalBytes &+= delta.knownLogicalBytes
            nodes[i].summary.knownAllocatedBytes &+= delta.knownAllocatedBytes
            nodes[i].summary.unknownLogicalItems += delta.unknownLogicalItems
            nodes[i].summary.unknownAllocatedItems += delta.unknownAllocatedItems
            nodes[i].summary.unreadableLocations += delta.unreadableLocations
            cursor = nodes[i].parent
        }
    }

    private func markListed(_ index: Int, outcome: ListingOutcome) {
        precondition(index < nodes.count, "列挙完了は項目の保存後に通知する")
        guard nodes[index].kind == .directory, !nodes[index].listingDone else { return }
        nodes[index].listingDone = true
        switch outcome {
        case .complete:
            break
        case .failed(let access, let message):
            let wasReadable = nodes[index].accessState == .readable
            nodes[index].accessState = access
            nodes[index].errorDescription = message
            nodes[index].subtreeIncomplete = true
            if wasReadable {
                counts.problemItems += 1
                addToAncestors(of: index, SizeSummary(unreadableLocations: 1))
            }
        case .interrupted(let message):
            // 列挙しきれなかった直下の項目がある
            nodes[index].subtreeIncomplete = true
            markUnvisited(index)
            if let message {
                nodes[index].errorDescription = message
                if nodes[index].accessState == .readable {
                    nodes[index].accessState = .error
                    counts.problemItems += 1
                }
            }
        }
        completeIfPossible(index)
    }

    /// 未走査の配下があることを自身と祖先に記録する。
    private func markUnvisited(_ index: Int) {
        var cursor = Int32(index)
        while cursor >= 0, !nodes[Int(cursor)].summary.hasUnvisitedDescendants {
            nodes[Int(cursor)].summary.hasUnvisitedDescendants = true
            cursor = nodes[Int(cursor)].parent
        }
    }

    /// 自身の列挙と子ディレクトリがすべて終わったディレクトリを確定し、親へ伝える。
    private func completeIfPossible(_ start: Int) {
        var index = start
        while true {
            let node = nodes[index]
            guard node.traversalState == .pending,
                  node.listingDone,
                  node.pendingChildDirectories == 0 else { return }
            nodes[index].traversalState = node.subtreeIncomplete ? .partial : .complete
            let parent = node.parent
            guard parent >= 0 else { return }
            let p = Int(parent)
            nodes[p].pendingChildDirectories -= 1
            if node.subtreeIncomplete {
                nodes[p].subtreeIncomplete = true
            }
            index = p
        }
    }

    // MARK: - 読み取り

    public var currentRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    public var currentCounts: ScanCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    public var rootID: ItemID? {
        lock.lock()
        defer { lock.unlock() }
        return nodes.isEmpty ? nil : ItemID(0)
    }

    public var itemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    public func item(_ id: ItemID) -> ScanItem? {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.indices.contains(id.index) else { return nil }
        return snapshot(id.index)
    }

    /// 直下の項目をサイズ順（既知サイズの降順・不明は末尾・同サイズは名前順）でページ取得する。
    public func children(of id: ItemID, offset: Int = 0, limit: Int = .max) -> ItemPage {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.indices.contains(id.index) else {
            return ItemPage(items: [], offset: 0, totalCount: 0, revision: revision, isProvisional: false)
        }
        return page(of: sortedChildren(id.index), offset: offset, limit: limit, isProvisional: false)
    }

    /// 同じ版・同じフォルダへの繰り返しの問い合わせ（ページ送り・Treemap）で再ソートしない。
    private func sortedChildren(_ index: Int) -> [Int32] {
        if let cache = childrenCache, cache.directory == index, cache.revision == revision {
            return cache.ids
        }
        // 兄弟は親が同じで名前も一意なので、パスによる比較は不要
        let ids = sortBySize(children[index], pathTieBreak: false)
        childrenCache = (index, revision, ids)
        return ids
    }

    /// Treemap 用に、サイズ順の上位 `limit` 件と、残りのうちサイズが 0 より大きい項目の件数・合計を同じ版で返す。
    public func childrenForTreemap(of id: ItemID, limit: Int) -> (page: ItemPage, remainderCount: Int, remainderKnownBytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.indices.contains(id.index) else {
            return (ItemPage(items: [], offset: 0, totalCount: 0, revision: revision, isProvisional: false), 0, 0)
        }
        let sorted = sortedChildren(id.index)
        let page = page(of: sorted, offset: 0, limit: limit, isProvisional: false)
        var restCount = 0
        var restBytes: Int64 = 0
        for child in sorted.dropFirst(page.items.count) {
            // サイズ順なので、0・不明が現れたら以降に面積を持つ項目はない
            guard let bytes = sortKey(Int(child)), bytes > 0 else { break }
            restCount += 1
            restBytes = TreemapLayout.saturatingAdd(restBytes, bytes)
        }
        return (page, restCount, restBytes)
    }

    /// スキャン全体の通常ファイルをサイズ順にページ取得する。
    ///
    /// 確定前は上位 `provisionalFileLimit` 件だけを返し、`isProvisional` を立てる。
    /// 確定後は全件の索引を一度だけ作り、以降の問い合わせで再ソートしない。
    public func largestFiles(offset: Int = 0, limit: Int = 100) -> ItemPage {
        lock.lock()
        defer { lock.unlock() }
        if isFinalized {
            if sortedFileIndex == nil {
                sortedFileIndex = sortBySize(fileIDs, pathTieBreak: true)
            }
            return page(of: sortedFileIndex!, offset: offset, limit: limit, isProvisional: false)
        }
        if provisionalCache?.revision != revision {
            provisionalCache = (revision, sortBySize(topFiles.elements, pathTieBreak: true))
        }
        return page(of: provisionalCache!.ids, offset: offset, limit: limit, isProvisional: true)
    }

    /// 確定後に全件の索引を前もって作る。UI の最初の問い合わせを待たせないため、保存スレッドから呼ぶ。
    public func prepareFileIndex() {
        _ = largestFiles(offset: 0, limit: 0)
    }

    /// ルートからの ID 列（パンくず用）。ルートが先頭。
    public func ancestry(of id: ItemID) -> [ItemID] {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.indices.contains(id.index) else { return [] }
        var result: [ItemID] = []
        var cursor = Int32(id.index)
        while cursor >= 0 {
            result.append(ItemID(cursor))
            cursor = nodes[Int(cursor)].parent
        }
        return result.reversed()
    }

    /// 項目の絶対パス。ノードにパスを保存せず、親をたどって組み立てる。
    public func path(of id: ItemID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.indices.contains(id.index) else { return nil }
        return pathLocked(id.index)
    }

    private func pathLocked(_ index: Int) -> String {
        var names: [String] = []
        var cursor = Int32(index)
        while cursor > 0 {
            names.append(nodes[Int(cursor)].name)
            cursor = nodes[Int(cursor)].parent
        }
        var path = rootPath
        for name in names.reversed() {
            path = PathUtilities.join(path, name)
        }
        return path
    }

    // MARK: - 内部

    private func snapshot(_ index: Int) -> ScanItem {
        let node = nodes[index]
        return ScanItem(
            id: ItemID(Int32(index)),
            parentID: node.parent >= 0 ? ItemID(node.parent) : nil,
            name: node.name,
            kind: node.kind,
            isPackage: node.isPackage,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            sizeSummary: node.summary,
            modifiedDate: node.modifiedDate,
            createdDate: node.createdDate,
            accessState: node.accessState,
            traversalState: node.traversalState,
            fileIdentity: node.fileIdentity,
            exclusionReason: node.exclusionReason,
            errorDescription: node.errorDescription
        )
    }

    private func page(of ids: [Int32], offset: Int, limit: Int, isProvisional: Bool) -> ItemPage {
        let start = min(max(0, offset), ids.count)
        let end = start + min(max(0, limit), ids.count - start)
        let items = ids[start..<end].map { snapshot(Int($0)) }
        return ItemPage(items: items, offset: start, totalCount: ids.count, revision: revision, isProvisional: isProvisional)
    }

    private func sortKey(_ index: Int) -> Int64? {
        // ノード全体をコピーしないよう、必要なフィールドだけを読む
        switch nodes[index].kind {
        case .file:
            return nodes[index].allocatedSize
        case .directory:
            return ScanItem.displayBytes(
                kind: .directory, ownSize: nil, knownTotal: nodes[index].summary.knownAllocatedBytes,
                accessState: nodes[index].accessState, traversalState: nodes[index].traversalState
            )
        case .symbolicLink, .other:
            return nil
        }
    }

    /// 既知サイズの降順、不明は末尾、同サイズは名前・相対パスの順。
    private func sizeOrder(_ lhs: Int32, _ rhs: Int32) -> Bool {
        let order = Self.compareSize(sortKey(Int(lhs)), sortKey(Int(rhs)))
        if order != 0 {
            return order < 0
        }
        let l = Int(lhs), r = Int(rhs)
        if nodes[l].name != nodes[r].name {
            return nodes[l].name < nodes[r].name
        }
        if nodes[l].parent != nodes[r].parent {
            let lp = pathLocked(Int(nodes[l].parent)), rp = pathLocked(Int(nodes[r].parent))
            if lp != rp {
                return lp < rp
            }
        }
        return lhs < rhs
    }

    /// サイズ順の比較。負なら lhs が先。不明（nil）は末尾。
    private static func compareSize(_ lhs: Int64?, _ rhs: Int64?) -> Int {
        switch (lhs, rhs) {
        case let (a?, b?):
            return a == b ? 0 : (a > b ? -1 : 1)
        case (.some, nil):
            return -1
        case (nil, .some):
            return 1
        case (nil, nil):
            return 0
        }
    }

    /// サイズの鍵を先に計算してから並べる。同サイズ・同名が多い大量のファイルでも、
    /// 親フォルダのパスは親ごとに一度だけ組み立てる。
    private func sortBySize(_ ids: [Int32], pathTieBreak: Bool) -> [Int32] {
        struct Key {
            let id: Int32
            let size: Int64?
        }
        var keys = ids.map { Key(id: $0, size: sortKey(Int($0))) }
        var parentPaths: [Int32: String] = [:]
        func parentPath(_ id: Int32) -> String {
            let parent = nodes[Int(id)].parent
            if let cached = parentPaths[parent] {
                return cached
            }
            let path = parent >= 0 ? pathLocked(Int(parent)) : ""
            parentPaths[parent] = path
            return path
        }
        keys.sort { lhs, rhs in
            let order = Self.compareSize(lhs.size, rhs.size)
            if order != 0 {
                return order < 0
            }
            let l = Int(lhs.id), r = Int(rhs.id)
            if nodes[l].name != nodes[r].name {
                return nodes[l].name < nodes[r].name
            }
            if pathTieBreak, nodes[l].parent != nodes[r].parent {
                let lp = parentPath(lhs.id), rp = parentPath(rhs.id)
                if lp != rp {
                    return lp < rp
                }
            }
            return lhs.id < rhs.id
        }
        return keys.map(\.id)
    }

    private func offerTopFile(_ id: Int32) {
        if topFiles.count < provisionalFileLimit {
            topFiles.push(id, isLower: lowerPriority)
        } else if let lowest = topFiles.peek, lowerPriority(lowest, id) {
            topFiles.replaceTop(id, isLower: lowerPriority)
        }
    }

    /// 暫定索引から先に追い出す側か（サイズ順で後ろ側か）。
    private func lowerPriority(_ lhs: Int32, _ rhs: Int32) -> Bool {
        sizeOrder(rhs, lhs)
    }
}

/// ID を比較関数で並べる最小ヒープ。比較関数はノード配列を参照するため、呼び出し側から渡す。
struct MinHeap {
    private(set) var elements: [Int32] = []

    var count: Int { elements.count }
    var peek: Int32? { elements.first }

    mutating func push(_ value: Int32, isLower: (Int32, Int32) -> Bool) {
        elements.append(value)
        siftUp(elements.count - 1, isLower: isLower)
    }

    mutating func replaceTop(_ value: Int32, isLower: (Int32, Int32) -> Bool) {
        guard !elements.isEmpty else { return push(value, isLower: isLower) }
        elements[0] = value
        siftDown(0, isLower: isLower)
    }

    private mutating func siftUp(_ start: Int, isLower: (Int32, Int32) -> Bool) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard isLower(elements[child], elements[parent]) else { return }
            elements.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int, isLower: (Int32, Int32) -> Bool) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < elements.count, isLower(elements[left], elements[candidate]) {
                candidate = left
            }
            if right < elements.count, isLower(elements[right], elements[candidate]) {
                candidate = right
            }
            guard candidate != parent else { return }
            elements.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
