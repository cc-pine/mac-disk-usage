import Foundation

/// 文字列前方一致に頼らず、パス成分単位で扱うための補助関数。
public enum PathUtilities {
    /// 連続する `/` と末尾の `/` を取り除く。`.` と `..` は解決しない（リンクを辿らないため）。
    public static func normalize(_ path: String) -> String {
        let parts = components(of: path)
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    public static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    public static func lastComponent(of path: String) -> String {
        components(of: path).last ?? "/"
    }

    public static func parent(of path: String) -> String? {
        var parts = components(of: path)
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    /// `path` が `ancestor` 自身またはその配下にあるか。成分単位で比較する。
    /// 絶対パスでないもの、`.` / `..` を含むものは判定できないため常に false。
    public static func isSameOrDescendant(_ path: String, of ancestor: String, caseInsensitive: Bool = false) -> Bool {
        guard isSafeAbsolute(path), isSafeAbsolute(ancestor) else { return false }
        var p = components(of: path)
        var a = components(of: ancestor)
        if caseInsensitive {
            p = p.map { $0.lowercased() }
            a = a.map { $0.lowercased() }
        }
        guard p.count >= a.count else { return false }
        return Array(p.prefix(a.count)) == a
    }

    /// `/` で始まり、`.` / `..` を含まないパスか。
    public static func isSafeAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !hasDotSegments(path)
    }

    /// `.` や `..` を含むパスは、リンクを辿らない比較ができないため安全でないとみなす。
    public static func hasDotSegments(_ path: String) -> Bool {
        components(of: path).contains { $0 == "." || $0 == ".." }
    }
}
