import Foundation

/// 1項目のメタデータ。ファイル内容は開かずに取得する。
public struct FileMetadata: Sendable, Equatable {
    public var kind: ItemKind
    public var logicalSize: Int64?
    public var allocatedSize: Int64?
    public var modifiedDate: Date?
    public var createdDate: Date?
    public var identity: FileIdentity?
    public var isPackage: Bool
    /// パッケージかどうかを判定できなかった（安全側ではパッケージとして扱う）
    public var isPackageUnknown: Bool
    /// 内容がローカルになく、読むとクラウドから取得される項目（macOS の dataless）
    public var isDataless: Bool
    /// ハードリンク数。取得できなければ nil
    public var linkCount: Int?

    public init(
        kind: ItemKind,
        logicalSize: Int64? = nil,
        allocatedSize: Int64? = nil,
        modifiedDate: Date? = nil,
        createdDate: Date? = nil,
        identity: FileIdentity? = nil,
        isPackage: Bool = false,
        isPackageUnknown: Bool = false,
        isDataless: Bool = false,
        linkCount: Int? = 1
    ) {
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modifiedDate = modifiedDate
        self.createdDate = createdDate
        self.identity = identity
        self.isPackage = isPackage
        self.isPackageUnknown = isPackageUnknown
        self.isDataless = isDataless
        self.linkCount = linkCount
    }

    /// 移動などの判定で使う、安全側のパッケージ判定
    public var mayBePackage: Bool {
        isPackage || isPackageUnknown
    }
}

/// ファイルシステム操作の失敗。利用者向けの短い説明と、調査用の errno を持つ。
public struct FileSystemError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case permissionDenied
        case notFound
        /// 走査中に別の実体へ置き換わった
        case changed
        /// クラウド上にだけあり、取得しないと読めない
        case cloudOnly
        case other
    }

    public let kind: Kind
    public let code: Int32
    public let message: String

    public init(kind: Kind, code: Int32, message: String) {
        self.kind = kind
        self.code = code
        self.message = message
    }

    public var accessState: AccessState {
        switch kind {
        case .permissionDenied: return .denied
        case .cloudOnly: return .notScanned
        case .notFound, .changed, .other: return .error
        }
    }
}

/// ディレクトリ直下の1項目。メタデータの取得失敗は項目ごとに持つ。
public struct DirectoryEntry: Sendable, Equatable {
    public var name: String
    public var metadata: Result<FileMetadata, FileSystemError>

    public init(name: String, metadata: Result<FileMetadata, FileSystemError>) {
        self.name = name
        self.metadata = metadata
    }
}

/// ディレクトリ列挙の結果。途中でエラーが起きた場合も、それまでの項目は返す。
public struct DirectoryListing: Sendable, Equatable {
    public var entries: [DirectoryEntry]
    public var error: FileSystemError?

    public init(entries: [DirectoryEntry], error: FileSystemError? = nil) {
        self.entries = entries
        self.error = error
    }
}

/// スキャナーが使うファイルシステムの境界。テストでは模擬実装に差し替える。
///
/// 実装はシンボリックリンクを辿らず（lstat 相当）、ファイル内容を開かず、
/// クラウド上だけの項目のダウンロードを要求してはならない。
public protocol FileSystemProvider: Sendable {
    /// パスの末尾がリンクでも辿らずにメタデータを返す。
    func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError>

    /// ディレクトリを開き、直下の項目とそのメタデータを返す。
    ///
    /// 開いたディレクトリが `expectedIdentity` と異なる（リンクや別の実体に置き換わった）場合は
    /// `.changed` で失敗する。直下のメタデータは開いたディレクトリからの相対で取得し、
    /// 途中の経路の置き換えに影響されないようにする。
    func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError>

    /// 走査スレッドの開始時に一度呼ぶ。クラウド項目の取得を抑止する設定などを行う。
    func prepareScanningThread()
}

extension FileSystemProvider {
    public func prepareScanningThread() {}
}
