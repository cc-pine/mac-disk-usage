import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// ユーザーが選んだ場所から走査範囲を組み立てる。
public enum ScopeResolver {
    /// 起動ディスクで配下走査から除外する別名経路・他のマウント先・デバイス領域
    public static let startupDiskExclusions: Set<String> = ["/System/Volumes", "/Volumes", "/dev"]
    /// 起動ディスクの Data ボリュームのマウント先
    public static let dataVolumePath = "/System/Volumes/Data"

    /// 起動ディスクの論理ルート `/`。System と Data のデバイスを一組として許可する。
    public static func startupDisk(provider: any FileSystemProvider = POSIXFileSystem()) -> ScanScope {
        var devices = Set<UInt64>()
        if case .success(let root) = provider.metadata(atPath: "/"), let identity = root.identity {
            devices.insert(identity.device)
        }
        if case .success(let data) = provider.metadata(atPath: dataVolumePath),
           data.kind == .directory, let identity = data.identity {
            devices.insert(identity.device)
        }
        return ScanScope(rootPath: "/", kind: .startupDisk, allowedDevices: devices, excludedPaths: startupDiskExclusions)!
    }

    /// フォルダまたはボリュームのルート。シンボリックリンクを含む場合は実体のパスに解決する。
    /// `/` が選ばれた場合は起動ディスクとして扱う。
    public static func scope(
        forPath path: String,
        isVolume: Bool,
        provider: any FileSystemProvider = POSIXFileSystem(),
        resolve: (String) -> String? = canonicalPath
    ) -> ScanScope? {
        guard let canonical = resolve(path), PathUtilities.isSafeAbsolute(canonical) else { return nil }
        if canonical == "/" {
            return startupDisk(provider: provider)
        }
        return ScanScope(rootPath: canonical, kind: isVolume ? .volume : .folder)
    }

    /// realpath による実体パス。解決できなければ nil。
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return PathUtilities.normalize(String(cString: resolved))
    }
}
