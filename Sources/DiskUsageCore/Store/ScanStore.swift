import Foundation

/// 一覧の1ページ。`revision` は問い合わせ時点のストアの版。
public struct ItemPage: Sendable, Equatable {
    public let items: [ScanItem]
    public let offset: Int
    public let totalCount: Int
    public let revision: Int
    /// 上位の一部だけを返している場合 true（スキャン中、または完了直後に全件の索引を作成中）
    public let isProvisional: Bool

    public init(items: [ScanItem], offset: Int, totalCount: Int, revision: Int, isProvisional: Bool) {
        self.items = items
        self.offset = offset
        self.totalCount = totalCount
        self.revision = revision
        self.isProvisional = isProvisional
    }
}

/// 場所の一覧で区別する項目の分類。アクセスできなかった場所と、方針による除外を混ぜない。
public enum ItemCategory: Sendable, Equatable {
    /// アクセス拒否・読み取りエラー・クラウド上のみなど、情報を取得できなかった項目
    case problems
    /// 別ボリューム・別経路・範囲規則により意図的に走査しなかった項目
    case excluded
}

public struct LocatedItem: Sendable, Equatable, Identifiable {
    public let item: ScanItem
    public let path: String

    public var id: ItemID { item.id }
}

public struct LocatedItemPage: Sendable, Equatable {
    public let items: [LocatedItem]
    public let offset: Int
    public let totalCount: Int
    public let revision: Int
}

/// スキャン項目と親子索引、フォルダ集計、通常ファイル索引を保持する。
///
/// 書き込みはスキャンの保存処理だけが行い、UI からは問い合わせだけを行う。
/// 内部状態は1つのロックで守り、ノードごとの監視オブジェクトや全ツリーの複製を作らない。
///
/// 1000 万件で 2 GB 以内に収めるため、ノードは塊単位の配列に 64 バイトずつ置き、名前は
/// 1つの領域に UTF-8 で詰め、子は兄弟の連結でたどる。集計はフォルダの分だけ別の表に持つ。
public final class ScanStore: @unchecked Sendable {
    /// 1ノードあたりの固定メモリ量。計測用。
    static var nodeStride: Int { MemoryLayout<Node>.stride }
    /// 1フォルダあたりの集計表の大きさ。計測用。
    static var directoryStride: Int { MemoryLayout<DirectoryInfo>.stride }

    public let rootPath: String
    /// 大きなファイル一覧の暫定索引に保持する件数
    public let provisionalFileLimit: Int

    private let lock = NSLock()
    /// 進捗通知用の版と件数だけを守る軽いロック。保存中でも本体のロックを待たずに読める。
    /// 取る順序は lock → statsLock のみ。
    private let statsLock = NSLock()
    private var publishedRevision = 0
    private var publishedCounts = ScanCounts()
    private let nodes = ChunkedBuffer<Node>()
    private let directories = ChunkedBuffer<DirectoryInfo>()
    private let names = NameStorage()
    /// デバイス番号の表。ノードには添字だけを持つ（1回のスキャンに現れるデバイスは少ない）
    private var devices: [UInt64] = []
    private var deviceSlots: [UInt64: UInt16] = [:]
    /// エラー説明。大半の項目は持たないため疎な辞書にする
    private var errorDescriptions: [Int32: String] = [:]
    private var counts = ScanCounts()
    private var revision = 0
    private var isFinalized = false
    private var topFiles = MinHeap()
    private let fileIDs = ChunkedBuffer<Int32>()
    /// 読み取れなかった項目（発見順）。件数は counts.problemItems と一致する
    private var problemIDs: [Int32] = []
    /// 範囲の方針で除外した項目（発見順）
    private var excludedIDs: [Int32] = []
    private var sortedFileIndex: [Int32]?
    private var isPreparingFileIndex = false
    /// 全件索引の完成を待つための条件変数（lock とは独立に取る）
    private let indexBuilt = NSCondition()
    private var isFileIndexBuilt = false
    private var provisionalCache: (revision: Int, ids: [Int32])?
    private var childrenCache: (directory: Int, revision: Int, ids: [Int32])?

    public init(rootPath: String, provisionalFileLimit: Int = 10_000) {
        self.rootPath = PathUtilities.normalize(rootPath)
        self.provisionalFileLimit = max(1, provisionalFileLimit)
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
            publishStats()
        }
    }

    private func publishStats() {
        statsLock.lock()
        publishedRevision = revision
        publishedCounts = counts
        statsLock.unlock()
    }

    /// 走査を終えた時点で未完了のディレクトリを部分結果として確定する。
    /// - Returns: 未完了のディレクトリが残っていたか
    @discardableResult
    public func finalize() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinalized else { return false }
        // ルートの走査が確定していれば、未完了のディレクトリは残っていない（全ノードを見なくてよい）
        let hasPending = !nodes.isEmpty && nodes[0].traversalState == .pending
        var hadUnvisited = false
        if hasPending {
            for index in 0..<nodes.count where nodes[index].directory >= 0 && nodes[index].traversalState == .pending {
                hadUnvisited = true
                nodes[index].traversalState = .partial
                if !nodes[index].listingDone {
                    if nodes[index].accessState == .readable {
                        nodes[index].accessState = .notScanned
                    }
                    markUnvisited(index)
                }
            }
        }
        isFinalized = true
        revision += 1
        publishStats()
        return hadUnvisited
    }

    private func insert(_ item: DiscoveredItem) {
        let index = nodes.count
        precondition(item.id.index == index, "ID は発見順に連続して採番する")
        let parent = item.parentID.map { Int32($0.index) } ?? -1
        precondition(parent < Int32(index), "親は子より先に保存する")
        precondition(parent >= 0 || index == 0, "ルート以外は親を持つ")
        precondition(parent < 0 || nodes[Int(parent)].directory >= 0, "親はフォルダ")

        // 負のサイズは取得値として扱えないため、保存時に一度だけ 0 へ補正する（ノードと集計で値を揃える）
        let logicalSize = item.logicalSize.map { max(0, $0) }
        let allocatedSize = item.allocatedSize.map { max(0, $0) }
        var traversal: TraversalState
        var listingDone = false
        var directorySummary = SizeSummary()
        if item.exclusionReason != nil {
            traversal = .excluded
        } else {
            traversal = item.kind == .directory ? .pending : .complete
            if item.kind == .directory, item.accessState != .readable {
                // 種類は分かったが中身を読めない。配下は列挙しない。
                directorySummary.unreadableLocations = 1
                traversal = .partial
                listingDone = true
            }
        }

        var node = Node(
            parent: parent,
            name: names.append(item.name),
            kind: item.kind,
            isPackage: item.isPackage,
            logicalSize: item.kind == .file ? logicalSize : nil,
            allocatedSize: item.kind == .file ? allocatedSize : nil,
            modifiedDate: item.modifiedDate,
            createdDate: item.createdDate,
            accessState: item.accessState,
            traversalState: traversal,
            exclusionReason: item.exclusionReason
        )
        node.listingDone = listingDone
        if let identity = item.fileIdentity, let slot = deviceSlot(identity.device) {
            node.deviceSlot = slot
            node.inode = identity.inode
        }
        let summary: SizeSummary
        if item.kind == .directory {
            node.directory = Int32(directories.count)
            directories.append(DirectoryInfo(directorySummary))
            summary = directorySummary
        } else {
            summary = node.ownSummary
        }
        if parent >= 0 {
            let p = Int(parent)
            let directory = Int(nodes[p].directory)
            node.nextSibling = directories[directory].firstChild
            directories[directory].firstChild = Int32(index)
            directories[directory].childCount += 1
            if traversal == .pending {
                directories[directory].pendingChildDirectories += 1
            } else if traversal == .partial {
                nodes[p].subtreeIncomplete = true
            }
        }
        nodes.append(node)
        if let message = item.errorDescription {
            errorDescriptions[Int32(index)] = message
        }
        if parent >= 0 {
            addToAncestors(of: Int(parent), summary)
        }

        updateCounts(for: item)
        if item.exclusionReason != nil {
            excludedIDs.append(Int32(index))
        } else if item.accessState != .readable {
            problemIDs.append(Int32(index))
        }
        if item.kind == .file, item.exclusionReason == nil {
            fileIDs.append(Int32(index))
            if item.allocatedSize != nil {
                offerTopFile(Int32(index))
            }
        }
    }

    /// デバイス番号の表の添字。表が満杯なら nil（識別情報を持たない項目として扱い、移動を断る）。
    private func deviceSlot(_ device: UInt64) -> UInt16? {
        if let slot = deviceSlots[device] {
            return slot
        }
        guard devices.count < Int(Node.noDevice) else { return nil }
        let slot = UInt16(devices.count)
        devices.append(device)
        deviceSlots[device] = slot
        return slot
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

    /// `start`（フォルダ）と、その祖先の集計に加える。
    private func addToAncestors(of start: Int, _ delta: SizeSummary) {
        guard delta != SizeSummary() else { return }
        var cursor = Int32(start)
        while cursor >= 0 {
            let i = Int(cursor)
            directories[Int(nodes[i].directory)].add(delta)
            cursor = nodes[i].parent
        }
    }

    private func markListed(_ index: Int, outcome: ListingOutcome) {
        precondition(nodes.contains(index: index), "列挙完了は項目の保存後に通知する")
        guard nodes[index].directory >= 0, !nodes[index].listingDone else { return }
        nodes[index].listingDone = true
        switch outcome {
        case .complete:
            break
        case .failed(let access, let message):
            let wasReadable = nodes[index].accessState == .readable
            nodes[index].accessState = access
            errorDescriptions[Int32(index)] = message
            nodes[index].subtreeIncomplete = true
            if wasReadable {
                counts.problemItems += 1
                problemIDs.append(Int32(index))
                addToAncestors(of: index, SizeSummary(unreadableLocations: 1))
            }
        case .interrupted(let message, let access):
            // 列挙しきれなかった直下の項目がある
            nodes[index].subtreeIncomplete = true
            markUnvisited(index)
            if let message {
                errorDescriptions[Int32(index)] = message
                if nodes[index].accessState == .readable {
                    nodes[index].accessState = access
                    counts.problemItems += 1
                    problemIDs.append(Int32(index))
                }
            }
        }
        completeIfPossible(index)
    }

    /// 未走査の配下があることを自身と祖先に記録する。
    private func markUnvisited(_ index: Int) {
        var cursor = Int32(index)
        while cursor >= 0, !nodes[Int(cursor)].hasUnvisitedDescendants {
            nodes[Int(cursor)].hasUnvisitedDescendants = true
            cursor = nodes[Int(cursor)].parent
        }
    }

    /// 自身の列挙と子ディレクトリがすべて終わったディレクトリを確定し、親へ伝える。
    private func completeIfPossible(_ start: Int) {
        var index = start
        while true {
            guard nodes[index].traversalState == .pending,
                  nodes[index].listingDone,
                  directories[Int(nodes[index].directory)].pendingChildDirectories == 0 else { return }
            let incomplete = nodes[index].subtreeIncomplete
            nodes[index].traversalState = incomplete ? .partial : .complete
            let parent = nodes[index].parent
            guard parent >= 0 else { return }
            let p = Int(parent)
            directories[Int(nodes[p].directory)].pendingChildDirectories -= 1
            if incomplete {
                nodes[p].subtreeIncomplete = true
            }
            index = p
        }
    }

    // MARK: - 読み取り

    /// 最後に保存し終えたバッチの版と件数を、同じ時点の組として返す。保存中でも待たずに読める。
    public var currentStats: (revision: Int, counts: ScanCounts) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (publishedRevision, publishedCounts)
    }

    /// 最後に保存し終えたバッチの版。保存中でも待たずに読める。
    public var currentRevision: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return publishedRevision
    }

    /// 最後に保存し終えたバッチ時点の件数。保存中でも待たずに読める。
    public var currentCounts: ScanCounts {
        statsLock.lock()
        defer { statsLock.unlock() }
        return publishedCounts
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
        guard nodes.contains(index: id.index) else { return nil }
        return snapshot(id.index)
    }

    /// 直下の項目をサイズ順（既知サイズの降順・不明は末尾・同サイズは名前順）でページ取得する。
    public func children(of id: ItemID, offset: Int = 0, limit: Int = .max) -> ItemPage {
        let sorted = sortedChildren(id.index)
        lock.lock()
        defer { lock.unlock() }
        guard let sorted else {
            return ItemPage(items: [], offset: 0, totalCount: 0, revision: revision, isProvisional: false)
        }
        return page(of: sorted, offset: offset, limit: limit, isProvisional: false)
    }

    /// 直下の ID をサイズ順に返す。ロックを持たずに呼ぶ。
    ///
    /// 鍵（サイズと名前の位置）だけをロック内で集め、並べ替えはロックの外で行う。数十万件のフォルダを
    /// 表示していても、保存処理と他の問い合わせを待たせない。名前のバイト列は書き込み後に動かないため、
    /// ロックの外でも読める。同じ版・同じフォルダへの繰り返しの問い合わせ（ページ送り・Treemap）では
    /// 並べ直さない。
    private func sortedChildren(_ index: Int) -> [Int32]? {
        struct Key {
            let size: Int64
            let name: UnsafeBufferPointer<UInt8>
            let id: Int32
        }
        lock.lock()
        guard nodes.contains(index: index) else {
            lock.unlock()
            return nil
        }
        if let cache = childrenCache, cache.directory == index, cache.revision == revision {
            let ids = cache.ids
            lock.unlock()
            return ids
        }
        let sortRevision = revision
        var keyed: [Key] = []
        let directory = Int(nodes[index].directory)
        if directory >= 0 {
            keyed.reserveCapacity(Int(directories[directory].childCount))
            var child = directories[directory].firstChild
            while child >= 0 {
                let c = Int(child)
                keyed.append(Key(size: sortKey(c), name: names.bytes(nodes[c].name), id: child))
                child = nodes[c].nextSibling
            }
        }
        lock.unlock()

        // 兄弟は親が同じで名前も一意なので、パスによる比較は不要
        keyed.sort { lhs, rhs in
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            let order = NameStorage.compare(lhs.name, rhs.name)
            return order != 0 ? order < 0 : lhs.id < rhs.id
        }
        let sorted = keyed.map(\.id)

        lock.lock()
        if revision == sortRevision {
            childrenCache = (index, sortRevision, sorted)
        }
        lock.unlock()
        return sorted
    }

    /// `child` が `parent` の直下でサイズ順の何番目か（0 始まり）。直下にない場合は nil。
    public func position(of child: ItemID, in parent: ItemID) -> Int? {
        sortedChildren(parent.index)?.firstIndex(of: child.rawValue)
    }

    /// Treemap 用に、サイズ順の上位 `limit` 件と、残りのうちサイズが 0 より大きい項目の件数・合計を同じ版で返す。
    public func childrenForTreemap(of id: ItemID, limit: Int) -> (page: ItemPage, remainderCount: Int, remainderKnownBytes: Int64) {
        let sorted = sortedChildren(id.index)
        lock.lock()
        defer { lock.unlock() }
        guard let sorted else {
            return (ItemPage(items: [], offset: 0, totalCount: 0, revision: revision, isProvisional: false), 0, 0)
        }
        let page = page(of: sorted, offset: 0, limit: limit, isProvisional: false)
        var restCount = 0
        var restBytes: Int64 = 0
        for child in sorted.dropFirst(page.items.count) {
            // 並べた時点より後にサイズが変わることがあるため、途中で打ち切らずに数える
            let bytes = sortKey(Int(child))
            guard bytes > 0 else { continue }
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
        if isFinalized, sortedFileIndex == nil, !isPreparingFileIndex {
            // 誰も索引を作っていなければ、このロックの中で作成役を引き受けてから外で作る
            // （確認と引き受けを分けると、作成中の別スレッドを待つ側に回ってしまう）
            isPreparingFileIndex = true
            lock.unlock()
            buildFileIndex()
            lock.lock()
        }
        if isFinalized, let sortedFileIndex {
            defer { lock.unlock() }
            return page(of: sortedFileIndex, offset: offset, limit: limit, isProvisional: false)
        }
        // スキャン中、または別スレッドが全件の索引を作成中は、暫定の上位を返して待たない
        if let cache = provisionalCache, cache.revision == revision {
            defer { lock.unlock() }
            return page(of: cache.ids, offset: offset, limit: limit, isProvisional: true)
        }
        // 暫定の上位は最大 provisionalFileLimit 件なので、ロックの中で並べる
        defer { lock.unlock() }
        let sorted = topFiles.elements.sorted { compareFiles($0, $1, parentOrder: comparePaths) < 0 }
        provisionalCache = (revision, sorted)
        return page(of: sorted, offset: offset, limit: limit, isProvisional: true)
    }

    /// 確定後に全件の索引を前もって作る。保存スレッドから呼ぶ。
    ///
    /// 別スレッドが作成中なら完成を待ってから戻る（終端イベントを索引の完成後に送るため）。
    public func prepareFileIndex() {
        lock.lock()
        if isPreparingFileIndex {
            lock.unlock()
            indexBuilt.lock()
            while !isFileIndexBuilt {
                indexBuilt.wait()
            }
            indexBuilt.unlock()
            return
        }
        guard isFinalized, sortedFileIndex == nil else {
            lock.unlock()
            return
        }
        isPreparingFileIndex = true
        lock.unlock()
        buildFileIndex()
    }

    /// 作成役を引き受けた（isPreparingFileIndex を立てた）スレッドだけが呼ぶ。
    ///
    /// 確定後のノードは変更されないため、ロックの外で読んで並べ、その間も UI の問い合わせを待たせない。
    private func buildFileIndex() {
        lock.lock()
        assert(isFinalized, "全件索引は確定後にだけ作る")
        lock.unlock()

        // 並べ替えの比較でノードや名前を読みに行くと、1000 万件では待ち時間が積み重なる。
        // 名前とパスを先に整数の順位へ置き換え、比較を鍵の中だけで済ませる。
        // 同じサイズ・同じ名前のファイルは親フォルダのパス順に並べる。パスの文字列を作らずに済むよう、
        // フォルダを名前順にたどった順番（パス順と一致する）を振っておく。
        let directoryRanks = directoryRanks()
        var keys: [FileKey] = []
        keys.reserveCapacity(fileIDs.count)
        for i in 0..<fileIDs.count {
            let id = fileIDs[i]
            let parent = Int(nodes[Int(id)].parent)
            // ルート自身がファイルの場合だけ親がない
            let rank = parent >= 0 ? directoryRanks[Int(nodes[parent].directory)] : -1
            keys.append(FileKey(size: sortKey(Int(id)), nameRank: 0, parentRank: rank, id: id))
        }
        assignNameRanks(&keys)
        keys.sort { lhs, rhs in
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            if lhs.nameRank != rhs.nameRank {
                return lhs.nameRank < rhs.nameRank
            }
            if lhs.parentRank != rhs.parentRank {
                return lhs.parentRank < rhs.parentRank
            }
            return lhs.id < rhs.id
        }
        let sorted = keys.map(\.id)
        keys = []

        lock.lock()
        sortedFileIndex = sorted
        isPreparingFileIndex = false
        lock.unlock()

        indexBuilt.lock()
        isFileIndexBuilt = true
        indexBuilt.broadcast()
        indexBuilt.unlock()
    }

    /// 全件索引の並べ替えの鍵。比較は整数だけで行う。
    private struct FileKey {
        let size: Int64
        /// 名前のバイト列の順位。同じ名前は同じ値
        var nameRank: UInt32
        /// 親フォルダのパスの順位
        let parentRank: Int32
        let id: Int32
    }

    /// 鍵ごとに名前の順位を振る。確定後にだけ呼ぶ。
    ///
    /// 同じ名前（`package.json` など）は多いため、まずハッシュ表で同じ名前をまとめ、異なる名前だけを
    /// 並べて順位を決める。ハッシュはプロセスごとに種が変わる `Hasher` を使い、名前を細工されても
    /// 衝突が偏らないようにする。
    private func assignNameRanks(_ keys: inout [FileKey]) {
        guard !keys.isEmpty else { return }
        var capacity = 16
        while capacity < keys.count + keys.count / 2 {
            capacity <<= 1
        }
        let mask = capacity - 1
        // 空きは 0、それ以外は「異なる名前」の番号 + 1
        var table = [UInt32](repeating: 0, count: capacity)
        var distinct: [NameStorage.Location] = []
        for i in keys.indices {
            let location = nodes[Int(keys[i].id)].name
            let bytes = names.bytes(location)
            var hasher = Hasher()
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
            var slot = hasher.finalize() & mask
            while true {
                let entry = table[slot]
                if entry == 0 {
                    distinct.append(location)
                    table[slot] = UInt32(distinct.count)
                    keys[i].nameRank = UInt32(distinct.count - 1)
                    break
                }
                let candidate = distinct[Int(entry - 1)]
                if candidate == location || NameStorage.compare(names.bytes(candidate), bytes) == 0 {
                    keys[i].nameRank = entry - 1
                    break
                }
                slot = (slot + 1) & mask
            }
        }
        table = []

        // 異なる名前だけを並べる。先頭 8 バイトを整数にした鍵で、多くの比較を名前を読まずに済ませる
        struct NameKey {
            let prefix: UInt64
            let index: UInt32
        }
        var order = distinct.indices.map { index -> NameKey in
            let bytes = names.bytes(distinct[index])
            var prefix: UInt64 = 0
            for j in 0..<8 {
                // 名前に NUL は含まれないため、短い名前の 0 埋めは辞書順を変えない
                prefix = prefix << 8 | UInt64(j < bytes.count ? bytes[j] : 0)
            }
            return NameKey(prefix: prefix, index: UInt32(index))
        }
        order.sort { lhs, rhs in
            if lhs.prefix != rhs.prefix {
                return lhs.prefix < rhs.prefix
            }
            return NameStorage.compare(names.bytes(distinct[Int(lhs.index)]), names.bytes(distinct[Int(rhs.index)])) < 0
        }
        var rankOf = [UInt32](repeating: 0, count: distinct.count)
        for (rank, key) in order.enumerated() {
            rankOf[Int(key.index)] = UInt32(rank)
        }
        for i in keys.indices {
            keys[i].nameRank = rankOf[Int(keys[i].nameRank)]
        }
    }

    /// フォルダの集計表の添字ごとに、ルートから子を名前順にたどった訪問順を返す。確定後にだけ呼ぶ。
    ///
    /// 訪問順の比較は、パスを成分ごとに比べた順（`comparePaths`）と一致する。
    private func directoryRanks() -> [Int32] {
        var ranks = [Int32](repeating: 0, count: directories.count)
        guard !nodes.isEmpty, nodes[0].directory >= 0 else { return ranks }
        var next: Int32 = 0
        var stack: [Int32] = [0]
        var subdirectories: [Int32] = []
        while let current = stack.popLast() {
            let c = Int(current)
            ranks[Int(nodes[c].directory)] = next
            next += 1
            subdirectories.removeAll(keepingCapacity: true)
            var child = directories[Int(nodes[c].directory)].firstChild
            while child >= 0 {
                if nodes[Int(child)].directory >= 0 {
                    subdirectories.append(child)
                }
                child = nodes[Int(child)].nextSibling
            }
            // 名前の大きい順に積み、小さい順に取り出す
            subdirectories.sort { compareSiblings($0, $1) > 0 }
            stack.append(contentsOf: subdirectories)
        }
        return ranks
    }

    /// 読み取れなかった場所、または範囲の方針で除外した場所を、発見順にパス付きで返す。
    public func locatedItems(_ category: ItemCategory, offset: Int = 0, limit: Int = 200) -> LocatedItemPage {
        lock.lock()
        defer { lock.unlock() }
        let ids = category == .problems ? problemIDs : excludedIDs
        let start = min(max(0, offset), ids.count)
        let end = start + min(max(0, limit), ids.count - start)
        let items = ids[start..<end].map { id in
            LocatedItem(item: snapshot(Int(id)), path: pathLocked(Int(id)))
        }
        return LocatedItemPage(items: items, offset: start, totalCount: ids.count, revision: revision)
    }

    /// ルートからの ID 列（パンくず用）。ルートが先頭。
    public func ancestry(of id: ItemID) -> [ItemID] {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.contains(index: id.index) else { return [] }
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
        guard nodes.contains(index: id.index) else { return nil }
        return pathLocked(id.index)
    }

    private func pathLocked(_ index: Int) -> String {
        var locations: [NameStorage.Location] = []
        var cursor = Int32(index)
        while cursor > 0 {
            locations.append(nodes[Int(cursor)].name)
            cursor = nodes[Int(cursor)].parent
        }
        var path = rootPath
        for location in locations.reversed() {
            path = PathUtilities.join(path, names.string(location))
        }
        return path
    }

    // MARK: - 内部

    private func snapshot(_ index: Int) -> ScanItem {
        let node = nodes[index]
        return ScanItem(
            id: ItemID(Int32(index)),
            parentID: node.parent >= 0 ? ItemID(node.parent) : nil,
            name: names.string(node.name),
            kind: node.kind,
            isPackage: node.isPackage,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            sizeSummary: node.directory >= 0
                ? directories[Int(node.directory)].summary(hasUnvisitedDescendants: node.hasUnvisitedDescendants)
                : node.ownSummary,
            modifiedDate: node.modifiedDate,
            createdDate: node.createdDate,
            accessState: node.accessState,
            traversalState: node.traversalState,
            fileIdentity: node.deviceSlot == Node.noDevice
                ? nil
                : FileIdentity(device: devices[Int(node.deviceSlot)], inode: node.inode),
            exclusionReason: node.exclusionReason,
            errorDescription: errorDescriptions[Int32(index)]
        )
    }

    private func page(of ids: [Int32], offset: Int, limit: Int, isProvisional: Bool) -> ItemPage {
        let start = min(max(0, offset), ids.count)
        let end = start + min(max(0, limit), ids.count - start)
        let items = ids[start..<end].map { snapshot(Int($0)) }
        return ItemPage(items: items, offset: start, totalCount: ids.count, revision: revision, isProvisional: isProvisional)
    }

    /// 並べ替えに使う割り当て済みサイズ。不明・数えない項目は -1（既知のサイズより後ろに並ぶ）。
    private func sortKey(_ index: Int) -> Int64 {
        let directory = Int(nodes[index].directory)
        if directory < 0 {
            return nodes[index].kind == .file ? nodes[index].allocatedSortKey : Node.unknownSize
        }
        return ScanItem.displayBytes(
            kind: .directory, ownSize: nil, knownTotal: directories[directory].knownAllocatedBytes,
            accessState: nodes[index].accessState, traversalState: nodes[index].traversalState
        ) ?? Node.unknownSize
    }

    /// ファイルの並び順。サイズの降順、同サイズは名前順、同名は親フォルダのパス順、最後に ID 順。
    /// 負なら lhs が先。
    private func compareFiles(_ lhs: Int32, _ rhs: Int32, parentOrder: (Int32, Int32) -> Int) -> Int {
        let l = Int(lhs), r = Int(rhs)
        let lSize = sortKey(l), rSize = sortKey(r)
        if lSize != rSize {
            return lSize > rSize ? -1 : 1
        }
        let order = NameStorage.compare(names.bytes(nodes[l].name), names.bytes(nodes[r].name))
        if order != 0 {
            return order
        }
        let lParent = nodes[l].parent, rParent = nodes[r].parent
        if lParent != rParent {
            let pathOrder = parentOrder(lParent, rParent)
            if pathOrder != 0 {
                return pathOrder
            }
        }
        return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
    }

    /// 2つのフォルダのパスを成分ごとに比べる。祖先は子孫より先。負なら lhs が先。
    private func comparePaths(_ lhs: Int32, _ rhs: Int32) -> Int {
        // 親のない項目（ルート）は先
        guard lhs >= 0, rhs >= 0 else {
            return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        }
        let lDepth = depth(lhs), rDepth = depth(rhs)
        var l = lhs, r = rhs
        for _ in 0..<max(0, lDepth - rDepth) {
            l = nodes[Int(l)].parent
        }
        for _ in 0..<max(0, rDepth - lDepth) {
            r = nodes[Int(r)].parent
        }
        if l == r {
            // 同じフォルダか、一方が他方の祖先（浅い方が先）
            return lDepth == rDepth ? 0 : (lDepth < rDepth ? -1 : 1)
        }
        while nodes[Int(l)].parent != nodes[Int(r)].parent {
            l = nodes[Int(l)].parent
            r = nodes[Int(r)].parent
        }
        return compareSiblings(l, r)
    }

    /// 同じ親を持つ項目の名前順。同名なら ID 順。
    private func compareSiblings(_ lhs: Int32, _ rhs: Int32) -> Int {
        let order = NameStorage.compare(names.bytes(nodes[Int(lhs)].name), names.bytes(nodes[Int(rhs)].name))
        if order != 0 {
            return order
        }
        return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
    }

    private func depth(_ index: Int32) -> Int {
        var depth = 0
        var cursor = nodes[Int(index)].parent
        while cursor >= 0 {
            depth += 1
            cursor = nodes[Int(cursor)].parent
        }
        return depth
    }

    private func offerTopFile(_ id: Int32) {
        if topFiles.count < provisionalFileLimit {
            topFiles.push(id, isLower: lowerPriority)
        } else if let lowest = topFiles.peek, lowerPriority(lowest, id) {
            topFiles.replaceTop(id, isLower: lowerPriority)
        }
    }

    /// 暫定索引から先に追い出す側か。保存処理の中で呼ぶため、名前やパスは比べずサイズと ID だけで決める
    /// （表示時には全候補を名前・パスの順に並べ直す）。
    private func lowerPriority(_ lhs: Int32, _ rhs: Int32) -> Bool {
        let l = sortKey(Int(lhs)), r = sortKey(Int(rhs))
        return l != r ? l < r : lhs > rhs
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
