import Foundation

/// スキャン内で一意な項目識別子。配列添字として使うため、スキャンをまたいで比較しない。
public struct ItemID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    var index: Int { Int(rawValue) }

    public static func < (lhs: ItemID, rhs: ItemID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "#\(rawValue)" }
}

public enum ItemKind: String, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

/// 項目そのものを読めたかどうか。列挙の完了度（`TraversalState`）とは別に保持する。
public enum AccessState: String, Sendable {
    case readable
    case denied
    case error
    case notScanned
}

/// ディレクトリ配下の列挙の完了度。
public enum TraversalState: String, Sendable {
    case pending
    case partial
    case complete
    case excluded
}

/// 走査範囲の方針による意図的な除外理由。アクセスエラーとは区別する。
public enum ExclusionReason: String, Sendable {
    /// 別のボリューム（入れ子のマウント）
    case otherVolume
    /// 既に訪問したディレクトリへの別経路
    case duplicatePath
    /// 起動ディスクの別名経路など、範囲規則による除外
    case scopeRule
}

/// 置換検知と別経路検知に使うファイルシステム上の識別情報。
public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// 既知の合計と不明件数を独立に持つ集計値。不明を 0 とみなさない。
public struct SizeSummary: Equatable, Sendable {
    public var knownLogicalBytes: Int64 = 0
    public var knownAllocatedBytes: Int64 = 0
    public var unknownLogicalItems: Int = 0
    public var unknownAllocatedItems: Int = 0
    public var unreadableLocations: Int = 0
    public var hasUnvisitedDescendants: Bool = false

    public init(
        knownLogicalBytes: Int64 = 0,
        knownAllocatedBytes: Int64 = 0,
        unknownLogicalItems: Int = 0,
        unknownAllocatedItems: Int = 0,
        unreadableLocations: Int = 0,
        hasUnvisitedDescendants: Bool = false
    ) {
        self.knownLogicalBytes = knownLogicalBytes
        self.knownAllocatedBytes = knownAllocatedBytes
        self.unknownLogicalItems = unknownLogicalItems
        self.unknownAllocatedItems = unknownAllocatedItems
        self.unreadableLocations = unreadableLocations
        self.hasUnvisitedDescendants = hasUnvisitedDescendants
    }

    /// 割り当て済みサイズの合計の一部が欠けているか。
    public var isIncomplete: Bool {
        unknownAllocatedItems > 0 || unreadableLocations > 0 || hasUnvisitedDescendants
    }

    /// 論理サイズの合計の一部が欠けているか。
    public var isLogicalIncomplete: Bool {
        unknownLogicalItems > 0 || unreadableLocations > 0 || hasUnvisitedDescendants
    }
}

/// UI に渡す項目の値スナップショット。ストア内部のノードとは別に作る。
public struct ScanItem: Identifiable, Equatable, Sendable {
    public let id: ItemID
    public let parentID: ItemID?
    public let name: String
    public let kind: ItemKind
    public let isPackage: Bool
    public let logicalSize: Int64?
    public let allocatedSize: Int64?
    public let sizeSummary: SizeSummary
    public let modifiedDate: Date?
    public let createdDate: Date?
    public let accessState: AccessState
    public let traversalState: TraversalState
    public let fileIdentity: FileIdentity?
    public let exclusionReason: ExclusionReason?
    public let errorDescription: String?

    public init(
        id: ItemID,
        parentID: ItemID?,
        name: String,
        kind: ItemKind,
        isPackage: Bool,
        logicalSize: Int64?,
        allocatedSize: Int64?,
        sizeSummary: SizeSummary,
        modifiedDate: Date?,
        createdDate: Date?,
        accessState: AccessState,
        traversalState: TraversalState,
        fileIdentity: FileIdentity?,
        exclusionReason: ExclusionReason?,
        errorDescription: String?
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.isPackage = isPackage
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.sizeSummary = sizeSummary
        self.modifiedDate = modifiedDate
        self.createdDate = createdDate
        self.accessState = accessState
        self.traversalState = traversalState
        self.fileIdentity = fileIdentity
        self.exclusionReason = exclusionReason
        self.errorDescription = errorDescription
    }

    /// 集計の方針で容量を数えない項目（リンク・特殊ファイル）か。取得失敗とは区別する。
    public var isNotCounted: Bool {
        kind == .symbolicLink || kind == .other && accessState == .readable
    }

    /// 並べ替えと Treemap に使う割り当て済みサイズ。取得できない・数えない項目は nil。
    public var displayAllocatedBytes: Int64? {
        Self.displayBytes(
            kind: kind, ownSize: allocatedSize, knownTotal: sizeSummary.knownAllocatedBytes,
            accessState: accessState, traversalState: traversalState
        )
    }

    public var displayLogicalBytes: Int64? {
        Self.displayBytes(
            kind: kind, ownSize: logicalSize, knownTotal: sizeSummary.knownLogicalBytes,
            accessState: accessState, traversalState: traversalState
        )
    }

    /// 表示中のサイズが完全な合計ではない（不明値・読めない場所・未走査・走査中を含む）か。
    public var isSizeIncomplete: Bool {
        switch kind {
        case .file:
            return allocatedSize == nil
        case .directory:
            return sizeSummary.isIncomplete || traversalState == .pending || traversalState == .partial
        case .symbolicLink, .other:
            return false
        }
    }

    /// ディレクトリは既知合計を返すが、除外したもの・中身を一つも読めなかったものは
    /// 0 bytes ではなく不明（nil）とする。
    static func displayBytes(
        kind: ItemKind,
        ownSize: Int64?,
        knownTotal: Int64,
        accessState: AccessState,
        traversalState: TraversalState
    ) -> Int64? {
        switch kind {
        case .file:
            return ownSize
        case .directory:
            if traversalState == .excluded {
                return nil
            }
            if accessState != .readable, knownTotal == 0 {
                return nil
            }
            return knownTotal
        case .symbolicLink, .other:
            return nil
        }
    }
}
