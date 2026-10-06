import Foundation

/// 画面に出す文言。不明値を 0 と表示せず、部分結果であることを併記する。言語は `L10n` に従う。
public enum DisplayText {
    public static func size(of item: ScanItem) -> String {
        if item.isNotCounted {
            return "—"
        }
        if item.traversalState == .excluded {
            return L10n.excluded
        }
        guard let bytes = item.displayAllocatedBytes else {
            return L10n.unknown
        }
        let text = ByteFormatting.string(bytes)
        return item.isSizeIncomplete ? L10n.incomplete(text) : text
    }

    public static func logicalSize(of item: ScanItem) -> String {
        if item.isNotCounted {
            return L10n.notCounted
        }
        if item.traversalState == .excluded {
            return L10n.excluded
        }
        guard let bytes = item.displayLogicalBytes else {
            return L10n.unknown
        }
        let text = ByteFormatting.string(bytes)
        if item.kind == .directory, item.sizeSummary.isLogicalIncomplete || item.traversalState != .complete {
            return L10n.incomplete(text)
        }
        return text
    }

    public static func allocatedSizeDetail(of item: ScanItem) -> String {
        if item.isNotCounted {
            return L10n.notCounted
        }
        return size(of: item)
    }

    public static func kind(of item: ScanItem) -> String {
        switch item.kind {
        case .file: return L10n.kindFile
        case .directory: return item.isPackage ? L10n.kindPackage : L10n.kindFolder
        case .symbolicLink: return L10n.kindSymbolicLink
        case .other: return item.accessState == .readable ? L10n.kindSpecialFile : L10n.unknown
        }
    }

    public static func access(of item: ScanItem) -> String {
        if let reason = item.exclusionReason {
            // 除外した項目は中身を読んでいないため「読み取り可」と示さない
            return L10n.excluded(because: exclusion(reason))
        }
        var parts: [String] = []
        switch item.accessState {
        case .readable: parts.append(L10n.accessReadable)
        case .denied: parts.append(L10n.accessDenied)
        case .error: parts.append(L10n.accessError)
        case .notScanned: parts.append(L10n.accessNotScanned)
        }
        if item.kind == .directory {
            switch item.traversalState {
            case .pending: parts.append(L10n.traversalScanning)
            case .partial: parts.append(L10n.traversalPartial)
            case .complete: break
            case .excluded: parts.append(L10n.excluded)
            }
        }
        return parts.joined(separator: L10n.listSeparator)
    }

    public static func exclusion(_ reason: ExclusionReason) -> String {
        switch reason {
        case .otherVolume: return L10n.exclusionOtherVolume
        case .duplicatePath: return L10n.exclusionDuplicatePath
        case .scopeRule: return L10n.exclusionScopeRule
        }
    }

    public static func state(_ state: ScanState?, isStale: Bool) -> String {
        let base: String
        switch state {
        case nil: base = L10n.stateNotScanned
        case .scanning?: base = L10n.stateScanning
        case .cancelling?: base = L10n.stateCancelling
        case .completed?: base = L10n.stateCompleted
        case .completedWithErrors?: base = L10n.stateCompletedWithErrors
        case .cancelled?: base = L10n.stateCancelled
        case .failed?: base = L10n.stateFailed
        }
        return isStale ? L10n.stale(base) : base
    }

    /// 名前やパスを確認ダイアログなどに出すとき、改行などの制御文字や文字の向きを変える
    /// 書式文字を目に見える形にする。名前で表示内容を偽装されないようにするため。
    public static func visible(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isControl = value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
            let isBidiControl = value == 0x200E || value == 0x200F || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value) || value == 0x061C
            if isControl || isBidiControl {
                result += String(format: "<U+%04X>", value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    public static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 {
            return L10n.seconds(seconds)
        }
        return L10n.minutesSeconds(seconds / 60, seconds % 60)
    }

    public static func date(_ date: Date?) -> String {
        guard let date else { return L10n.unknown }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
