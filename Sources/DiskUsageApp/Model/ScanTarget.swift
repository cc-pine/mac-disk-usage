import Foundation
import DiskUsageCore

/// 開始画面に並べるボリューム。
struct VolumeEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isStartupDisk: Bool
    let capacity: VolumeCapacity

    var id: String { path }

    static func == (lhs: VolumeEntry, rhs: VolumeEntry) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    /// macOS が報告するマウント済みボリューム。隠しボリュームは除く。
    static func mountedVolumes(now: Date = Date()) -> [VolumeEntry] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeEntry? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false {
                return nil
            }
            let path = PathUtilities.normalize(url.path)
            let capacity = VolumeCapacity.fetch(forPath: path, now: now)
            let name = values?.volumeName ?? capacity.volumeName ?? PathUtilities.lastComponent(of: path)
            return VolumeEntry(path: path, name: name, isStartupDisk: path == "/", capacity: capacity)
        }
        .sorted { lhs, rhs in
            if lhs.isStartupDisk != rhs.isStartupDisk {
                return lhs.isStartupDisk
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// スキャン対象。ボリュームまたは任意のフォルダ。
enum ScanTarget: Hashable {
    case volume(VolumeEntry)
    case folder(URL)

    var path: String {
        switch self {
        case .volume(let volume): return volume.path
        case .folder(let url): return PathUtilities.normalize(url.path)
        }
    }

    var displayName: String {
        switch self {
        case .volume(let volume): return volume.name
        case .folder(let url): return FileManager.default.displayName(atPath: url.path)
        }
    }

    var isVolume: Bool {
        if case .volume = self { return true }
        return false
    }
}
