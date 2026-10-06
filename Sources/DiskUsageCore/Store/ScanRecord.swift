import Foundation

/// スキャナーが列挙した1項目。ID はスキャナーが発見順に採番し、ストアは同じ順に保存する。
public struct DiscoveredItem: Sendable {
    public var id: ItemID
    public var parentID: ItemID?
    public var name: String
    public var kind: ItemKind
    public var isPackage: Bool
    public var logicalSize: Int64?
    public var allocatedSize: Int64?
    public var modifiedDate: Date?
    public var createdDate: Date?
    public var accessState: AccessState
    public var fileIdentity: FileIdentity?
    /// 方針による除外。設定されていればディレクトリでも列挙しない。
    public var exclusionReason: ExclusionReason?
    public var errorDescription: String?

    public init(
        id: ItemID,
        parentID: ItemID?,
        name: String,
        kind: ItemKind,
        isPackage: Bool = false,
        logicalSize: Int64? = nil,
        allocatedSize: Int64? = nil,
        modifiedDate: Date? = nil,
        createdDate: Date? = nil,
        accessState: AccessState = .readable,
        fileIdentity: FileIdentity? = nil,
        exclusionReason: ExclusionReason? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.isPackage = isPackage
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modifiedDate = modifiedDate
        self.createdDate = createdDate
        self.accessState = accessState
        self.fileIdentity = fileIdentity
        self.exclusionReason = exclusionReason
        self.errorDescription = errorDescription
    }
}

/// ディレクトリの直下を列挙し終えた結果。
public enum ListingOutcome: Sendable, Equatable {
    /// 直下の項目をすべて列挙した
    case complete
    /// ディレクトリ自体を読めなかった。配下の件数は推測しない。
    case failed(AccessState, String)
    /// 途中で列挙エラーが起きた、またはキャンセルで中断した
    case interrupted(String?, access: AccessState = .error)
}

/// 保存用バッチの1要素。
public enum ScanRecord: Sendable {
    case item(DiscoveredItem)
    case directoryListed(ItemID, ListingOutcome)
}
