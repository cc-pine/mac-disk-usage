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
        listDirectory(atPath: path, expectedIdentity: expectedIdentity, isCancelled: { false })
    }

    public func listDirectory(
        atPath path: String,
        expectedIdentity: FileIdentity?,
        isCancelled: () -> Bool
    ) -> Result<DirectoryListing, FileSystemError> {
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
            // 巨大なフォルダでもキャンセルを待たせない（それまでの項目を返し、走査側が中断を記録する）
            if entries.count % 1024 == 1023, isCancelled() {
                break
            }
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

    private static let strerrorLock = NSLock()

    /// strerror は再入可能ではないため、走査スレッドと UI 側の確認が同時に呼ばないようにする。
    static func systemMessage(_ code: Int32) -> String {
        strerrorLock.lock()
        defer { strerrorLock.unlock() }
        return String(cString: strerror(code))
    }

    /// errno を利用者向けの短い日本語の説明に変える。調査用に errno の番号を末尾に残す。
    static func error(_ code: Int32) -> FileSystemError {
        func message(_ text: String) -> String {
            "\(text)（errno \(code)）"
        }
        switch code {
        case EACCES, EPERM:
            return FileSystemError(kind: .permissionDenied, code: code, message: message("アクセスが拒否されました"))
        case ENOENT:
            return FileSystemError(kind: .notFound, code: code, message: message("見つかりません。走査中に移動・削除された可能性があります"))
        case ENOTDIR:
            return FileSystemError(kind: .notFound, code: code, message: message("フォルダではなくなりました"))
        case EDEADLK:
            // dataless 項目の取得を抑止した結果
            return FileSystemError(kind: .cloudOnly, code: code, message: "クラウド上にのみある項目です")
        case ENAMETOOLONG:
            return FileSystemError(kind: .other, code: code, message: message("パスが長すぎるため読み取れません"))
        case EIO:
            return FileSystemError(kind: .other, code: code, message: message("ディスクの読み取りでエラーが起きました"))
        case ETIMEDOUT:
            return FileSystemError(kind: .other, code: code, message: message("応答がないため読み取れませんでした"))
        default:
            return FileSystemError(kind: .other, code: code, message: message("読み取りに失敗しました: \(systemMessage(code))"))
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
