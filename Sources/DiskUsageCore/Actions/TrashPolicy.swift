import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// ゴミ箱へ移動できない理由。UI には `message` を表示する。
public enum TrashBlockReason: Error, Equatable, Sendable {
    case scanNotFinished
    case operationInProgress
    case notRegularFile
    case unreadable
    case scanRoot
    case protectedLocation(String)
    case insidePackage
    case outsideScope
    case unsafePath
    case identityUnavailable
    case multipleHardLinks
    case alreadyMoved
    case notInCurrentResult

    public var message: String {
        switch self {
        case .scanNotFinished: return "スキャン中と、スキャンの中止処理中は移動できません。"
        case .operationInProgress: return "別のゴミ箱操作を実行中です。"
        case .notRegularFile: return "移動できるのは通常のファイルだけです。"
        case .unreadable: return "項目を読み取れなかったため移動できません。"
        case .scanRoot: return "スキャン対象そのものは移動できません。"
        case .protectedLocation(let root): return "保護された場所（\(root)）の項目は移動できません。"
        case .insidePackage: return "アプリなどのパッケージ内部の項目は移動できません。"
        case .outsideScope: return "スキャン範囲外の項目は移動できません。"
        case .unsafePath: return "場所を安全に確認できないため移動できません。"
        case .identityUnavailable: return "項目を識別できないため移動できません。"
        case .multipleHardLinks: return "ほかの場所からも参照されている（ハードリンクがある）ファイルは移動できません。"
        case .alreadyMoved: return "この項目は移動済みです。"
        case .notInCurrentResult: return "現在のスキャン結果に含まれない項目です。"
        }
    }
}

/// ゴミ箱移動を禁止する場所の定義（DECISIONS.md の「保護対象パス」）。
///
/// 判定は成分単位・大文字小文字を区別しない比較で行う。`*` は任意の1成分に一致する。
public struct TrashPolicy: Sendable {
    /// 起動ディスクの絶対パスで指定する保護対象
    public static let systemRoots = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc", "/var", "/tmp",
        "/dev", "/cores", "/opt", "/Applications", "/Users/*/Library", "/Users/*/.Trash",
    ]

    /// 起動ディスク以外のボリューム（`/Volumes/<名前>`）のルートからの相対で指定する保護対象。
    /// 別の macOS のシステム領域、ボリュームごとのゴミ箱・索引・履歴など。
    public static let volumeRelativeRoots = [
        "System", "Library", "private", "Applications", "usr", "bin", "sbin", "cores", "opt",
        "Users/*/Library", "Users/*/.Trash",
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        "Backups.backupdb", ".MobileBackups",
    ]

    public let protectedRoots: [String]

    /// - Parameter homeDirectories: ホームディレクトリ。実体パスと元のパスの両方を渡す。
    public init(homeDirectories: [String] = TrashPolicy.currentHomeDirectories()) {
        var roots = Self.systemRoots
        for home in homeDirectories where PathUtilities.isSafeAbsolute(home) && home != "/" {
            let normalized = PathUtilities.normalize(home)
            roots.append(PathUtilities.join(normalized, "Library"))
            roots.append(PathUtilities.join(normalized, ".Trash"))
        }
        for relative in Self.volumeRelativeRoots {
            roots.append("/Volumes/*/" + relative)
        }
        protectedRoots = roots
    }

    public init(homeDirectory: String) {
        self.init(homeDirectories: [homeDirectory])
    }

    public init(protectedRoots: [String]) {
        self.protectedRoots = protectedRoots
    }

    /// 該当する保護対象のルート。
    ///
    /// - Parameter volumeRoots: パス上にある別ボリュームのマウント先（`/Volumes` 以外に
    ///   マウントされたものを含む）。それぞれに `volumeRelativeRoots` を当てはめる。
    public func protectedRoot(containing path: String, volumeRoots: [String] = []) -> String? {
        guard PathUtilities.isSafeAbsolute(path) else { return "/" }
        let components = PathUtilities.components(of: path).map { $0.lowercased() }
        let mountPatterns = volumeRoots
            .filter { PathUtilities.isSafeAbsolute($0) && $0 != "/" }
            .flatMap { root in Self.volumeRelativeRoots.map { PathUtilities.join(PathUtilities.normalize(root), $0) } }
        return (protectedRoots + mountPatterns).first { root in
            let pattern = PathUtilities.components(of: root).map { $0.lowercased() }
            guard components.count >= pattern.count else { return false }
            return zip(pattern, components).allSatisfy { $0 == "*" || $0 == $1 }
        }
    }

    /// 利用者のホームディレクトリ。Sandbox の影響を受けないパスワードデータベースの値と、
    /// その実体パスの両方を返す。
    public static func currentHomeDirectories() -> [String] {
        var homes: [String] = []
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            homes.append(String(cString: directory))
        }
        homes.append(NSHomeDirectory())
        let canonical = homes.compactMap(ScopeResolver.canonicalPath)
        return Array(Set(homes.map(PathUtilities.normalize) + canonical)).sorted()
    }
}
