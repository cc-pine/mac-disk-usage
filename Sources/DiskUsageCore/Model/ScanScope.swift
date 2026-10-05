import Foundation

/// 走査範囲。ルートと、配下で除外するパス・許可するデバイスを保持する。
public struct ScanScope: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 起動ディスクの論理ルート `/`。System / Data を一組として扱う。
        case startupDisk
        /// 起動ディスク以外のボリュームのルート
        case volume
        /// ユーザーが選んだフォルダ
        case folder
    }

    /// 正規化済みの絶対パス
    public let rootPath: String
    public let kind: Kind
    /// 配下で入ってよいデバイス番号。空の場合はルートのデバイスだけを許可する。
    public let allowedDevices: Set<UInt64>
    /// 配下走査から除外する絶対パス。ルート自身には適用しない。
    public let excludedPaths: Set<String>

    /// 絶対パスでない、または `.` / `..` を含むルートは受け付けない。
    public init?(rootPath: String, kind: Kind, allowedDevices: Set<UInt64> = [], excludedPaths: Set<String> = []) {
        guard PathUtilities.isSafeAbsolute(rootPath),
              excludedPaths.allSatisfy(PathUtilities.isSafeAbsolute) else {
            return nil
        }
        self.rootPath = PathUtilities.normalize(rootPath)
        self.kind = kind
        self.allowedDevices = allowedDevices
        self.excludedPaths = Set(excludedPaths.map(PathUtilities.normalize))
    }

    public var displayName: String {
        rootPath == "/" ? "/" : PathUtilities.lastComponent(of: rootPath)
    }
}
