import Foundation

/// 10進単位（1 GB = 10^9 bytes）での容量表記。集計は丸め前の整数で行い、表示時だけ丸める。
public enum ByteFormatting {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB", "EB"]

    public static func string(_ bytes: Int64) -> String {
        if bytes < 0 {
            return "-" + string(bytes == Int64.min ? Int64.max : -bytes)
        }
        if bytes < 1000 {
            return "\(bytes) \(L10n.bytesUnit)"
        }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        // 999.95 KB のような丸め繰り上がりを次の単位へ送る
        if (value * 10).rounded() >= 10_000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        return formatFixed(value, digits: 1) + " " + units[unitIndex]
    }

    /// 取得不能な値を 0 に置き換えずに表記する。
    public static func string(_ bytes: Int64?, unknown: String = L10n.unknown) -> String {
        guard let bytes else { return unknown }
        return string(bytes)
    }

    /// 既知合計と不明件数を併記する。例: 「10.0 GB・一部未取得」
    public static func summaryString(_ summary: SizeSummary) -> String {
        let base = string(summary.knownAllocatedBytes)
        return summary.isIncomplete ? L10n.incomplete(base) : base
    }

    private static func formatFixed(_ value: Double, digits: Int) -> String {
        // ロケールに依存しない小数点表記
        var multiplier = 1.0
        for _ in 0..<digits { multiplier *= 10 }
        let scaled = Int64((value * multiplier).rounded())
        guard digits > 0 else { return String(scaled) }
        let divisor = Int64(multiplier)
        let integerPart = scaled / divisor
        var fraction = String(scaled % divisor)
        while fraction.count < digits { fraction = "0" + fraction }
        return "\(integerPart).\(fraction)"
    }
}
