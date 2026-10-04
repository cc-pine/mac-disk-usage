import Foundation

/// スキャンごとに新しく割り当てる識別子。旧スキャンのイベントや問い合わせ結果を排除するために使う。
public struct ScanID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}

/// 1回のスキャンのライフサイクル。
///
/// スキャンは毎回新しいセッションとして `scanning` から始める（「idle / 終端状態 → scanning」は
/// セッションの作り直しで表す）。セッション内では
/// `scanning → completed | completedWithErrors | failed`、`scanning → cancelling → cancelled`
/// の遷移だけを許す。
public enum ScanState: String, Sendable {
    case scanning
    case cancelling
    case completed
    case completedWithErrors
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .scanning, .cancelling:
            return false
        case .completed, .completedWithErrors, .cancelled, .failed:
            return true
        }
    }

    /// 結果が対象範囲の全情報を含まない可能性があるか。
    public var isPartial: Bool {
        self != .completed
    }

    func canTransition(to next: ScanState) -> Bool {
        switch (self, next) {
        case (.scanning, .completed), (.scanning, .completedWithErrors), (.scanning, .failed),
             (.scanning, .cancelling), (.cancelling, .cancelled):
            return true
        default:
            return false
        }
    }
}

/// 走査の件数。読めないフォルダの内部件数は推測で加えない。
public struct ScanCounts: Equatable, Sendable {
    /// 列挙して記録した項目の総数（ルートを含む）
    public var enumeratedItems: Int = 0
    public var files: Int = 0
    public var directories: Int = 0
    public var symbolicLinks: Int = 0
    public var otherItems: Int = 0
    /// アクセス拒否・読み取りエラー・消失などの問題があった項目数
    public var problemItems: Int = 0
    /// 範囲の方針によって意図的に除外した項目数
    public var excludedItems: Int = 0

    public init() {}
}

/// 進捗通知の内容。UI 用で、最新の値だけを保持すればよい。
public struct ScanProgress: Equatable, Sendable {
    public let scanID: ScanID
    public let revision: Int
    public let state: ScanState
    public let counts: ScanCounts
    public let startedAt: Date
    public let finishedAt: Date?
    public let elapsed: TimeInterval

    public init(
        scanID: ScanID,
        revision: Int,
        state: ScanState,
        counts: ScanCounts,
        startedAt: Date,
        finishedAt: Date?,
        elapsed: TimeInterval
    ) {
        self.scanID = scanID
        self.revision = revision
        self.state = state
        self.counts = counts
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.elapsed = elapsed
    }
}
