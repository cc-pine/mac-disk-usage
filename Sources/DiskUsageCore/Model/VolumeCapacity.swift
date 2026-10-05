import Foundation

/// macOS が報告するボリューム容量情報。走査集計から算出する値ではない。
///
/// 総容量と空き容量は同じ取得元（同じボリューム・同じ時刻）の値だけを組にする。
/// 差分を「削除可能」や「アクセス不能領域」と推定しない。
public struct VolumeCapacity: Equatable, Sendable {
    public let volumeName: String?
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let fetchedAt: Date

    public init(volumeName: String?, totalBytes: Int64?, availableBytes: Int64?, fetchedAt: Date) {
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.fetchedAt = fetchedAt
    }

    /// 総容量と空き容量の両方が分かる場合だけ、OS が報告する「総容量 − 空き容量」を返す。
    ///
    /// 取得キーは `volumeTotalCapacityKey` と `volumeAvailableCapacityKey`（同じ statfs 由来）の組とし、
    /// Finder が使う `volumeAvailableCapacityForImportantUsageKey` とは混ぜない。そのため Finder の
    /// 表示とは差が出ることがある。APFS ではコンテナ全体の値になる。走査集計からは算出しない。
    public var usedBytes: Int64? {
        guard let totalBytes, let availableBytes, totalBytes >= availableBytes else { return nil }
        return totalBytes - availableBytes
    }

    /// 指定パスを含むボリュームの容量を OS から取得する。取得できない値は nil。
    public static func fetch(forPath path: String, now: Date = Date()) -> VolumeCapacity {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        return VolumeCapacity(
            volumeName: values?.volumeName,
            totalBytes: values?.volumeTotalCapacity.map(Int64.init),
            availableBytes: values?.volumeAvailableCapacity.map(Int64.init),
            fetchedAt: now
        )
    }
}
