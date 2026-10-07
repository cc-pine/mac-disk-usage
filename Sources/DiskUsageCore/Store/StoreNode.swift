import Foundation

extension ScanStore {
    /// ストア内部のノード（64 バイト）。1000 万件規模でのメモリを抑えるため、欠損値は番兵値で持ち、
    /// 状態は1バイトに詰める。
    ///
    /// 外からは Optional や列挙型の計算プロパティとして読み書きし、表現の違いをストアの他の部分に
    /// 漏らさない。名前は `NameStorage`、デバイス番号はストアの表、フォルダの集計は
    /// `DirectoryInfo`、エラー説明はストアの疎な辞書に持つ。
    struct Node {
        // 64 ビットの値を先に並べ、詰め物が入らないようにする（Swift は宣言順に配置する）
        private var storedLogicalSize: Int64 = Node.unknownSize
        private var storedAllocatedSize: Int64 = Node.unknownSize
        private var storedModified: Double = .nan
        private var storedCreated: Double = .nan
        var inode: UInt64 = 0
        var parent: Int32
        /// 同じ親の次の子（-1 で終わり）。子は親の `DirectoryInfo.firstChild` からたどる
        var nextSibling: Int32 = -1
        /// フォルダの集計表の添字。フォルダ以外は -1
        var directory: Int32 = -1
        var name: NameStorage.Location
        /// デバイス番号の表の添字。`noDevice` なら識別情報なし
        var deviceSlot: UInt16 = Node.noDevice
        /// 種類・アクセス・走査状態・除外理由を 2 ビットずつ
        private var states: UInt8 = 0
        private var flags: UInt8 = 0

        static let unknownSize: Int64 = -1
        static let noDevice = UInt16.max

        init(
            parent: Int32,
            name: NameStorage.Location,
            kind: ItemKind,
            isPackage: Bool,
            logicalSize: Int64?,
            allocatedSize: Int64?,
            modifiedDate: Date?,
            createdDate: Date?,
            accessState: AccessState,
            traversalState: TraversalState,
            exclusionReason: ExclusionReason?
        ) {
            self.parent = parent
            self.name = name
            self.kind = kind
            self.isPackage = isPackage
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.modifiedDate = modifiedDate
            self.createdDate = createdDate
            self.accessState = accessState
            self.traversalState = traversalState
            self.exclusionReason = exclusionReason
        }

        var logicalSize: Int64? {
            get { storedLogicalSize >= 0 ? storedLogicalSize : nil }
            set { storedLogicalSize = newValue.map { max(0, $0) } ?? Node.unknownSize }
        }

        var allocatedSize: Int64? {
            get { storedAllocatedSize >= 0 ? storedAllocatedSize : nil }
            set { storedAllocatedSize = newValue.map { max(0, $0) } ?? Node.unknownSize }
        }

        /// 並べ替え用の割り当て済みサイズ。不明は -1（既知のサイズより必ず小さい）
        var allocatedSortKey: Int64 { storedAllocatedSize }

        var modifiedDate: Date? {
            get { storedModified.isNaN ? nil : Date(timeIntervalSinceReferenceDate: storedModified) }
            set { storedModified = newValue?.timeIntervalSinceReferenceDate ?? .nan }
        }

        var createdDate: Date? {
            get { storedCreated.isNaN ? nil : Date(timeIntervalSinceReferenceDate: storedCreated) }
            set { storedCreated = newValue?.timeIntervalSinceReferenceDate ?? .nan }
        }

        var kind: ItemKind {
            get {
                switch states & 0b11 {
                case 0: .file
                case 1: .directory
                case 2: .symbolicLink
                default: .other
                }
            }
            set {
                let code: UInt8 = switch newValue {
                case .file: 0
                case .directory: 1
                case .symbolicLink: 2
                case .other: 3
                }
                states = states & ~0b11 | code
            }
        }

        var accessState: AccessState {
            get {
                switch states >> 2 & 0b11 {
                case 0: .readable
                case 1: .denied
                case 2: .error
                default: .notScanned
                }
            }
            set {
                let code: UInt8 = switch newValue {
                case .readable: 0
                case .denied: 1
                case .error: 2
                case .notScanned: 3
                }
                states = states & ~(0b11 << 2) | code << 2
            }
        }

        var traversalState: TraversalState {
            get {
                switch states >> 4 & 0b11 {
                case 0: .pending
                case 1: .partial
                case 2: .complete
                default: .excluded
                }
            }
            set {
                let code: UInt8 = switch newValue {
                case .pending: 0
                case .partial: 1
                case .complete: 2
                case .excluded: 3
                }
                states = states & ~(0b11 << 4) | code << 4
            }
        }

        var exclusionReason: ExclusionReason? {
            get {
                switch states >> 6 {
                case 0: nil
                case 1: .otherVolume
                case 2: .duplicatePath
                default: .scopeRule
                }
            }
            set {
                let code: UInt8 = switch newValue {
                case nil: 0
                case .otherVolume: 1
                case .duplicatePath: 2
                case .scopeRule: 3
                }
                states = states & 0b0011_1111 | code << 6
            }
        }

        var isPackage: Bool {
            get { flag(0b0001) }
            set { setFlag(0b0001, newValue) }
        }

        /// 直下の列挙を終えた（フォルダのみ）
        var listingDone: Bool {
            get { flag(0b0010) }
            set { setFlag(0b0010, newValue) }
        }

        /// 配下に列挙エラー・キャンセルがあった（フォルダのみ）
        var subtreeIncomplete: Bool {
            get { flag(0b0100) }
            set { setFlag(0b0100, newValue) }
        }

        /// 未走査の配下がある（フォルダのみ）。`SizeSummary.hasUnvisitedDescendants` に当たる
        var hasUnvisitedDescendants: Bool {
            get { flag(0b1000) }
            set { setFlag(0b1000, newValue) }
        }

        private func flag(_ mask: UInt8) -> Bool {
            flags & mask != 0
        }

        private mutating func setFlag(_ mask: UInt8, _ value: Bool) {
            flags = value ? flags | mask : flags & ~mask
        }

        /// フォルダ以外の項目が集計に加える値。保存時に決まり、後から変わらない。
        var ownSummary: SizeSummary {
            guard exclusionReason == nil else { return SizeSummary() }
            switch kind {
            case .file:
                let logical = logicalSize, allocated = allocatedSize
                return SizeSummary(
                    knownLogicalBytes: logical ?? 0,
                    knownAllocatedBytes: allocated ?? 0,
                    unknownLogicalItems: logical == nil ? 1 : 0,
                    unknownAllocatedItems: allocated == nil ? 1 : 0
                )
            case .other where accessState != .readable:
                // メタデータを取得できなかった項目。サイズを 0 とみなさず不明として数える。
                return SizeSummary(unknownLogicalItems: 1, unknownAllocatedItems: 1)
            case .directory, .symbolicLink, .other:
                return SizeSummary()
            }
        }
    }

    /// フォルダの集計と子の索引（40 バイト）。フォルダの分だけ持つ。件数は Int32 で持ち、溢れたら上限で止める。
    struct DirectoryInfo {
        var knownLogicalBytes: Int64 = 0
        var knownAllocatedBytes: Int64 = 0
        var unknownLogicalItems: Int32 = 0
        var unknownAllocatedItems: Int32 = 0
        var unreadableLocations: Int32 = 0
        /// 未完了の子フォルダ数
        var pendingChildDirectories: Int32 = 0
        /// 最後に保存した子（-1 なら子なし）。`Node.nextSibling` で残りをたどる
        var firstChild: Int32 = -1
        var childCount: Int32 = 0

        init() {}

        init(_ summary: SizeSummary) {
            add(summary)
        }

        func summary(hasUnvisitedDescendants: Bool) -> SizeSummary {
            SizeSummary(
                knownLogicalBytes: knownLogicalBytes,
                knownAllocatedBytes: knownAllocatedBytes,
                unknownLogicalItems: Int(unknownLogicalItems),
                unknownAllocatedItems: Int(unknownAllocatedItems),
                unreadableLocations: Int(unreadableLocations),
                hasUnvisitedDescendants: hasUnvisitedDescendants
            )
        }

        /// 子孫からの差分加算
        mutating func add(_ delta: SizeSummary) {
            // 巨大な sparse file などで負の合計に回り込まないよう、上限で止める
            knownLogicalBytes = TreemapLayout.saturatingAdd(knownLogicalBytes, delta.knownLogicalBytes)
            knownAllocatedBytes = TreemapLayout.saturatingAdd(knownAllocatedBytes, delta.knownAllocatedBytes)
            unknownLogicalItems = Int32(clamping: Int(unknownLogicalItems) + delta.unknownLogicalItems)
            unknownAllocatedItems = Int32(clamping: Int(unknownAllocatedItems) + delta.unknownAllocatedItems)
            unreadableLocations = Int32(clamping: Int(unreadableLocations) + delta.unreadableLocations)
        }
    }
}
