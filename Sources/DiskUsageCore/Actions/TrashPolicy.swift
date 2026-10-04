import Foundation

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
    case alreadyMoved
    case notInCurrentResult

    public var message: String {
        switch self {
        case .scanNotFinished: return "スキャン中・キャンセル待ちの間は移動できません。"
        case .operationInProgress: return "別のゴミ箱操作を実行中です。"
        case .notRegularFile: return "初版で移動できるのは通常ファイル1件だけです。"
        case .unreadable: return "項目を読み取れなかったため移動できません。"
        case .scanRoot: return "スキャン対象そのものは移動できません。"
        case .protectedLocation(let root): return "保護された場所（\(root)）の項目は移動できません。"
        case .insidePackage: return "アプリなどのパッケージ内部の項目は移動できません。"
        case .outsideScope: return "スキャン範囲外の項目は移動できません。"
        case .unsafePath: return "場所を安全に確認できないため移動できません。"
        case .identityUnavailable: return "項目を識別できないため移動できません。"
        case .alreadyMoved: return "この項目は移動済みです。"
        case .notInCurrentResult: return "現在のスキャン結果に含まれない項目です。"
        }
    }
}

/// ゴミ箱移動を禁止する場所の定義（DECISIONS.md の「保護対象パス」）。
public struct TrashPolicy: Sendable {
    public static let systemRoots = [
        "/System", "/Library", "/bin", "/sbin", "/usr", "/private", "/etc", "/var", "/tmp",
        "/dev", "/cores", "/opt", "/Applications",
    ]

    public let protectedRoots: [String]

    public init(homeDirectory: String = NSHomeDirectory()) {
        var roots = Self.systemRoots
        if PathUtilities.isSafeAbsolute(homeDirectory), homeDirectory != "/" {
            roots.append(PathUtilities.join(PathUtilities.normalize(homeDirectory), "Library"))
            roots.append(PathUtilities.join(PathUtilities.normalize(homeDirectory), ".Trash"))
        }
        protectedRoots = roots
    }

    public init(protectedRoots: [String]) {
        self.protectedRoots = protectedRoots
    }

    /// 該当する保護対象のルート。大文字・小文字を区別せず、成分単位で比較する。
    public func protectedRoot(containing path: String) -> String? {
        protectedRoots.first { PathUtilities.isSameOrDescendant(path, of: $0, caseInsensitive: true) }
    }
}
