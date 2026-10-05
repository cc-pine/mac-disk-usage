import Foundation
@testable import DiskUsageCore

/// メモリ上の模擬ファイルシステム。パス成分の木として項目を持つ。
final class MockFileSystem: FileSystemProvider, @unchecked Sendable {
    struct Entry {
        var metadata: FileMetadata
        var listError: FileSystemError?
        var metadataError: FileSystemError?
        /// 列挙は成功するが、この件数を返した後に中断する
        var interruptAfter: Int?
        var interruptError = FileSystemError(kind: .other, code: 5, message: "Input/output error")
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var childNames: [String: [String]] = [:]
    private var nextInode: UInt64 = 100
    private var storedOnList: (@Sendable (String) -> Void)?
    private var storedListedPaths: [String] = []

    /// 列挙するたびに呼ばれる（キャンセル競合のテスト用）
    var onList: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnList }
        set { lock.lock(); storedOnList = newValue; lock.unlock() }
    }

    var listedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedListedPaths
    }

    init(rootDevice: UInt64 = 1) {
        entries["/"] = Entry(metadata: FileMetadata(kind: .directory, identity: FileIdentity(device: rootDevice, inode: 2)))
    }

    @discardableResult
    func dir(_ path: String, device: UInt64 = 1, inode: UInt64? = nil, isPackage: Bool = false, isDataless: Bool = false) -> MockFileSystem {
        add(path, FileMetadata(kind: .directory, identity: identity(device, inode), isPackage: isPackage, isDataless: isDataless))
    }

    @discardableResult
    func file(_ path: String, allocated: Int64?, logical: Int64? = nil, device: UInt64 = 1, inode: UInt64? = nil) -> MockFileSystem {
        add(path, FileMetadata(
            kind: .file, logicalSize: logical ?? allocated, allocatedSize: allocated,
            modifiedDate: Date(timeIntervalSince1970: 1_000), identity: identity(device, inode)
        ))
    }

    @discardableResult
    func link(_ path: String) -> MockFileSystem {
        add(path, FileMetadata(kind: .symbolicLink, identity: identity(1, nil)))
    }

    func denyListing(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path]?.listError = FileSystemError(kind: .permissionDenied, code: 13, message: "Permission denied")
    }

    func failMetadata(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path]?.metadataError = FileSystemError(kind: .notFound, code: 2, message: "No such file or directory")
    }

    func interruptListing(_ path: String, after count: Int, error: FileSystemError? = nil) {
        lock.lock()
        defer { lock.unlock() }
        entries[path]?.interruptAfter = count
        if let error {
            entries[path]?.interruptError = error
        }
    }

    func remove(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = nil
        if let parent = PathUtilities.parent(of: path) {
            childNames[parent]?.removeAll { $0 == PathUtilities.lastComponent(of: path) }
        }
    }

    /// 既存の親の下に、指定のメタデータで項目を置く（移動の再現用）
    func place(_ path: String, _ metadata: FileMetadata) {
        _ = add(path, metadata)
    }

    func replace(_ path: String, with metadata: FileMetadata) {
        lock.lock()
        defer { lock.unlock() }
        entries[path]?.metadata = metadata
    }

    func metadata(atPath path: String) -> Result<FileMetadata, FileSystemError> {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path] else {
            return .failure(FileSystemError(kind: .notFound, code: 2, message: "No such file or directory"))
        }
        if let error = entry.metadataError {
            return .failure(error)
        }
        return .success(entry.metadata)
    }

    func listDirectory(atPath path: String, expectedIdentity: FileIdentity?) -> Result<DirectoryListing, FileSystemError> {
        lock.lock()
        storedListedPaths.append(path)
        let hook = storedOnList
        lock.unlock()
        hook?(path)

        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.metadata.kind == .directory else {
            return .failure(FileSystemError(kind: .changed, code: 20, message: "Not a directory"))
        }
        if let expectedIdentity, entry.metadata.identity != expectedIdentity {
            return .failure(FileSystemError(kind: .changed, code: 0, message: "replaced"))
        }
        if let error = entry.listError {
            return .failure(error)
        }
        var names = childNames[path] ?? []
        var listError: FileSystemError?
        if let limit = entry.interruptAfter {
            names = Array(names.prefix(limit))
            listError = entry.interruptError
        }
        let listed = names.map { name -> DirectoryEntry in
            let child = path == "/" ? "/" + name : path + "/" + name
            guard let childEntry = entries[child] else {
                return DirectoryEntry(name: name, metadata: .failure(FileSystemError(kind: .notFound, code: 2, message: "No such file or directory")))
            }
            if let error = childEntry.metadataError {
                return DirectoryEntry(name: name, metadata: .failure(error))
            }
            return DirectoryEntry(name: name, metadata: .success(childEntry.metadata))
        }
        return .success(DirectoryListing(entries: listed, error: listError))
    }

    private func identity(_ device: UInt64, _ inode: UInt64?) -> FileIdentity {
        if let inode {
            return FileIdentity(device: device, inode: inode)
        }
        lock.lock()
        defer { lock.unlock() }
        nextInode += 1
        return FileIdentity(device: device, inode: nextInode)
    }

    private func add(_ path: String, _ metadata: FileMetadata) -> MockFileSystem {
        lock.lock()
        defer { lock.unlock() }
        // 深い階層のテストで O(深さ²) にならないよう、正規化済みのパスだけを受け付けて末尾で分割する
        precondition(path.hasPrefix("/") && !path.hasSuffix("/") && !path.contains("//"), "正規化済みのパスを渡す: \(path)")
        entries[path] = Entry(metadata: metadata)
        let slash = path.lastIndex(of: "/")!
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        precondition(entries[parent] != nil, "親を先に作る: \(parent)")
        childNames[parent, default: []].append(String(path[path.index(after: slash)...]))
        return self
    }
}

extension FileSystemScanner {
    /// テスト用: 全バッチをストアへ保存しながら走査する。
    func run(into store: ScanStore, isCancelled: () -> Bool = { false }) -> ScanTermination {
        run(isCancelled: isCancelled) { store.apply($0) }
    }
}
