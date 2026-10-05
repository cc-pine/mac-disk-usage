import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// lstat / openat 系による実ファイルシステム実装。
///
/// - シンボリックリンクは辿らない（`lstat`、`O_NOFOLLOW`、`AT_SYMLINK_NOFOLLOW`）。
/// - ディレクトリは開いた後で (device, inode) を確かめ、直下の項目は開いた記述子からの相対で取得する。
/// - ファイル内容は開かない。割り当て済みサイズは `st_blocks * 512` を使う。
/// - macOS では走査スレッドで dataless 項目の取得を抑止し、クラウド上だけのフォルダは列挙しない。
/// - パッケージ判定は macOS でだけ URL リソース値から取得する（ローカルにあるディレクトリのみ）。
public struct POSIXFileSystem: FileSystemProvider {
    public init() {}

    public func prepareScanningThread() {
        #if os(macOS)
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES(3), IOPOL_SCOPE_THREAD(1),
        // IOPOL_MATERIALIZE_DATALESS_FILES_OFF(1): このスレッドから dataless 項目を取得させない
        _ = setiopolicy_np(3, 1, 1)
        #endif
    }

    public func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError> {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return .failure(Self.error(errno))
        }
        return .success(Self.metadata(info, packagePath: path))
    }

    public func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError> {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                return .failure(FileSystemError(kind: .changed, code: code, message: "フォルダではなくなりました"))
            }
            return .failure(Self.error(code))
        }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            let code = errno
            close(fd)
            return .failure(Self.error(code))
        }
        if let expectedIdentity, Self.identity(opened) != expectedIdentity {
            close(fd)
            return .failure(FileSystemError(kind: .changed, code: 0, message: "走査中に別の項目へ置き換わりました"))
        }
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            return .failure(Self.error(code))
        }
        defer { closedir(dir) }

        var entries: [DirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                let code = errno
                if code != 0 {
                    return .success(DirectoryListing(entries: entries, error: Self.error(code)))
                }
                break
            }
            let name = Self.name(of: entry)
            if name == "." || name == ".." {
                continue
            }
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                let metadata = Self.metadata(info, packagePath: PathUtilities.join(path, name))
                entries.append(DirectoryEntry(name: name, metadata: .success(metadata)))
            } else {
                entries.append(DirectoryEntry(name: name, metadata: .failure(Self.error(errno))))
            }
        }
        return .success(DirectoryListing(entries: entries))
    }

    // MARK: - 変換

    static func metadata(_ info: stat, packagePath: String) -> FileMetadata {
        let kind = kind(mode: info.st_mode)
        var metadata = FileMetadata(kind: kind)
        metadata.identity = identity(info)
        metadata.modifiedDate = modifiedDate(info)
        metadata.createdDate = createdDate(info)
        metadata.isDataless = isDataless(info)
        metadata.linkCount = Int(info.st_nlink)
        if kind == .file {
            metadata.logicalSize = Int64(info.st_size)
            // 異常な st_blocks（FUSE・ネットワークなど）で桁あふれさせず、不明として扱う
            let (allocated, overflow) = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
            metadata.allocatedSize = overflow || allocated < 0 ? nil : allocated
        }
        if kind == .directory {
            if metadata.isDataless {
                // 取得を伴う問い合わせを避ける。判定できないものとして扱う
                metadata.isPackageUnknown = true
            } else if let isPackage = isPackage(packagePath) {
                metadata.isPackage = isPackage
            } else {
                metadata.isPackageUnknown = true
            }
        }
        return metadata
    }

    static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino))
    }

    static func kind(mode: mode_t) -> ItemKind {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    static func error(_ code: Int32) -> FileSystemError {
        let message = String(cString: strerror(code))
        switch code {
        case EACCES, EPERM:
            return FileSystemError(kind: .permissionDenied, code: code, message: message)
        case ENOENT, ENOTDIR:
            return FileSystemError(kind: .notFound, code: code, message: message)
        case EDEADLK:
            // dataless 項目の取得を抑止した結果
            return FileSystemError(kind: .cloudOnly, code: code, message: "クラウド上にだけある項目です")
        default:
            return FileSystemError(kind: .other, code: code, message: message)
        }
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                String(cString: $0)
            }
        }
    }

    private static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    private static func modifiedDate(_ info: stat) -> Date {
        #if canImport(Darwin)
        return date(info.st_mtimespec)
        #else
        return date(info.st_mtim)
        #endif
    }

    private static func createdDate(_ info: stat) -> Date? {
        #if canImport(Darwin)
        // 作成日時を持たないファイルシステムでは 0 が入るため、1970年ではなく不明とする
        let birth = info.st_birthtimespec
        if birth.tv_sec == 0, birth.tv_nsec == 0 {
            return nil
        }
        return date(birth)
        #else
        return nil
        #endif
    }

    private static func isDataless(_ info: stat) -> Bool {
        #if canImport(Darwin)
        // SF_DATALESS (0x40000000)
        return info.st_flags & 0x4000_0000 != 0
        #else
        return false
        #endif
    }

    /// パッケージ判定。判定できなければ nil。
    private static func isPackage(_ path: String) -> Bool? {
        #if os(macOS)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.isPackageKey]) else { return nil }
        return values.isPackage
        #else
        return false
        #endif
    }
}
