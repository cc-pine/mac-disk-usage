import Foundation

extension ScanStore {
    /// ストア内部のノード。100万件規模でのメモリを抑えるため、欠損値は番兵値で持つ。
    ///
    /// 外からは Optional の計算プロパティとして読み書きし、表現の違いをストアの他の部分に漏らさない。
    /// エラー説明はほとんどの項目で空なので、ノードではなくストアの疎な辞書に持つ。
    struct Node {
        var name: String
        private var storedLogicalSize: Int64 = Node.unknownSize
        private var storedAllocatedSize: Int64 = Node.unknownSize
        private var storedModified: Double = .nan
        private var storedCreated: Double = .nan
        private var storedDevice: UInt64 = 0
        private var storedInode: UInt64 = 0
        private var storedSummary = PackedSummary()
        var parent: Int32
        /// 未完了の子ディレクトリ数
        var pendingChildDirectories: Int32 = 0
        var kind: ItemKind
        var isPackage: Bool
        var accessState: AccessState
        var traversalState: TraversalState
        var exclusionReason: ExclusionReason?
        private var hasIdentity = false
        var listingDone = false
        /// 配下に列挙エラー・キャンセルがあった
        var subtreeIncomplete = false

        private static let unknownSize: Int64 = -1

        init(
            parent: Int32,
            name: String,
            kind: ItemKind,
            isPackage: Bool,
            logicalSize: Int64?,
            allocatedSize: Int64?,
            summary: SizeSummary,
            modifiedDate: Date?,
            createdDate: Date?,
            accessState: AccessState,
            traversalState: TraversalState,
            fileIdentity: FileIdentity?,
            exclusionReason: ExclusionReason?,
            listingDone: Bool
        ) {
            self.parent = parent
            self.name = name
            self.kind = kind
            self.isPackage = isPackage
            self.accessState = accessState
            self.traversalState = traversalState
            self.exclusionReason = exclusionReason
            self.listingDone = listingDone
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.summary = summary
            self.modifiedDate = modifiedDate
            self.createdDate = createdDate
            self.fileIdentity = fileIdentity
        }

        var logicalSize: Int64? {
            get { storedLogicalSize >= 0 ? storedLogicalSize : nil }
            set { storedLogicalSize = newValue.map { max(0, $0) } ?? Node.unknownSize }
        }

        var allocatedSize: Int64? {
            get { storedAllocatedSize >= 0 ? storedAllocatedSize : nil }
            set { storedAllocatedSize = newValue.map { max(0, $0) } ?? Node.unknownSize }
        }

        var modifiedDate: Date? {
            get { storedModified.isNaN ? nil : Date(timeIntervalSinceReferenceDate: storedModified) }
            set { storedModified = newValue?.timeIntervalSinceReferenceDate ?? .nan }
        }

        var createdDate: Date? {
            get { storedCreated.isNaN ? nil : Date(timeIntervalSinceReferenceDate: storedCreated) }
            set { storedCreated = newValue?.timeIntervalSinceReferenceDate ?? .nan }
        }

        var fileIdentity: FileIdentity? {
            get { hasIdentity ? FileIdentity(device: storedDevice, inode: storedInode) : nil }
            set {
                hasIdentity = newValue != nil
                storedDevice = newValue?.device ?? 0
                storedInode = newValue?.inode ?? 0
            }
        }

        var summary: SizeSummary {
            get { storedSummary.expanded }
            set { storedSummary = PackedSummary(newValue) }
        }

        /// 並べ替えで頻繁に読むため、SizeSummary を組み立てずに直接返す
        var knownAllocatedBytes: Int64 { storedSummary.knownAllocatedBytes }

        var hasUnvisitedDescendants: Bool {
            get { storedSummary.hasUnvisitedDescendants }
            set { storedSummary.hasUnvisitedDescendants = newValue }
        }

        /// 祖先への差分加算。件数は Int32 で持ち、溢れたら上限で止める。
        mutating func add(_ delta: SizeSummary) {
            storedSummary.knownLogicalBytes &+= delta.knownLogicalBytes
            storedSummary.knownAllocatedBytes &+= delta.knownAllocatedBytes
            storedSummary.unknownLogicalItems = PackedSummary.adding(storedSummary.unknownLogicalItems, delta.unknownLogicalItems)
            storedSummary.unknownAllocatedItems = PackedSummary.adding(storedSummary.unknownAllocatedItems, delta.unknownAllocatedItems)
            storedSummary.unreadableLocations = PackedSummary.adding(storedSummary.unreadableLocations, delta.unreadableLocations)
        }
    }

    /// SizeSummary の詰めた表現（件数を Int32 で持つ）。
    struct PackedSummary {
        var knownLogicalBytes: Int64 = 0
        var knownAllocatedBytes: Int64 = 0
        var unknownLogicalItems: Int32 = 0
        var unknownAllocatedItems: Int32 = 0
        var unreadableLocations: Int32 = 0
        var hasUnvisitedDescendants = false

        init() {}

        init(_ summary: SizeSummary) {
            knownLogicalBytes = summary.knownLogicalBytes
            knownAllocatedBytes = summary.knownAllocatedBytes
            unknownLogicalItems = Self.clamp(summary.unknownLogicalItems)
            unknownAllocatedItems = Self.clamp(summary.unknownAllocatedItems)
            unreadableLocations = Self.clamp(summary.unreadableLocations)
            hasUnvisitedDescendants = summary.hasUnvisitedDescendants
        }

        var expanded: SizeSummary {
            SizeSummary(
                knownLogicalBytes: knownLogicalBytes,
                knownAllocatedBytes: knownAllocatedBytes,
                unknownLogicalItems: Int(unknownLogicalItems),
                unknownAllocatedItems: Int(unknownAllocatedItems),
                unreadableLocations: Int(unreadableLocations),
                hasUnvisitedDescendants: hasUnvisitedDescendants
            )
        }

        static func clamp(_ value: Int) -> Int32 {
            Int32(clamping: value)
        }

        static func adding(_ lhs: Int32, _ rhs: Int) -> Int32 {
            Int32(clamping: Int(lhs) + rhs)
        }
    }
}
