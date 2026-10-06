import Foundation

/// 画面に出す文言。不明値を 0 と表示せず、部分結果であることを併記する。
public enum DisplayText {
    public static func size(of item: ScanItem) -> String {
        if item.isNotCounted {
            return "—"
        }
        if item.traversalState == .excluded {
            return "除外"
        }
        guard let bytes = item.displayAllocatedBytes else {
            return "不明"
        }
        let text = ByteFormatting.string(bytes)
        return item.isSizeIncomplete ? "\(text)・一部未取得" : text
    }

    public static func logicalSize(of item: ScanItem) -> String {
        if item.isNotCounted {
            return "—（集計対象外）"
        }
        if item.traversalState == .excluded {
            return "除外"
        }
        guard let bytes = item.displayLogicalBytes else {
            return "不明"
        }
        let text = ByteFormatting.string(bytes)
        if item.kind == .directory, item.sizeSummary.isLogicalIncomplete || item.traversalState != .complete {
            return "\(text)・一部未取得"
        }
        return text
    }

    public static func allocatedSizeDetail(of item: ScanItem) -> String {
        if item.isNotCounted {
            return "—（集計対象外）"
        }
        return size(of: item)
    }

    public static func kind(of item: ScanItem) -> String {
        switch item.kind {
        case .file: return "ファイル"
        case .directory: return item.isPackage ? "パッケージ" : "フォルダ"
        case .symbolicLink: return "シンボリックリンク"
        case .other: return item.accessState == .readable ? "特殊ファイル" : "不明"
        }
    }

    public static func access(of item: ScanItem) -> String {
        if let reason = item.exclusionReason {
            // 除外した項目は中身を読んでいないため「読み取り可」と示さない
            return "除外（\(exclusion(reason))）"
        }
        var parts: [String] = []
        switch item.accessState {
        case .readable: parts.append("読み取り可")
        case .denied: parts.append("アクセス拒否")
        case .error: parts.append("読み取りエラー")
        case .notScanned: parts.append("未走査")
        }
        if let reason = item.exclusionReason {
            parts.append(exclusion(reason))
        } else if item.kind == .directory {
            switch item.traversalState {
            case .pending: parts.append("走査中")
            case .partial: parts.append("一部のみ走査")
            case .complete: break
            case .excluded: parts.append("除外")
            }
        }
        return parts.joined(separator: "・")
    }

    public static func exclusion(_ reason: ExclusionReason) -> String {
        switch reason {
        case .otherVolume: return "別のボリューム"
        case .duplicatePath: return "同じフォルダへの別経路"
        case .scopeRule: return "起動ディスクの範囲規則"
        }
    }

    public static func state(_ state: ScanState?, isStale: Bool) -> String {
        let base: String
        switch state {
        case nil: base = "未スキャン"
        case .scanning?: base = "スキャン中（部分結果）"
        case .cancelling?: base = "中止しています…"
        case .completed?: base = "完了"
        case .completedWithErrors?: base = "完了（一部未取得）"
        case .cancelled?: base = "中止（部分結果）"
        case .failed?: base = "失敗"
        }
        return isStale ? "\(base)・結果が古くなっています" : base
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
            return "\(seconds)秒"
        }
        return "\(seconds / 60)分\(seconds % 60)秒"
    }

    public static func date(_ date: Date?) -> String {
        guard let date else { return "不明" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
