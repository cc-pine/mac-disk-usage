import Foundation

/// 走査の終わり方。
public enum ScanTermination: Sendable, Equatable {
    /// 範囲内の列挙を最後まで行った
    case finished
    /// キャンセル要求により列挙を止めた
    case cancelled
    /// ルートを列挙できなかった
    case rootFailed(FileSystemError)
}

/// 指定範囲を単一ワーカーで列挙し、保存用レコードをバッチで渡す同期スキャナー。
///
/// MainActor 以外のスレッドから呼び出す前提のブロッキング処理。
/// 深い階層でもスタックを枯渇させないよう、再帰ではなく明示的なスタックで走査する。
public struct FileSystemScanner: Sendable {
    public let scope: ScanScope
    public let provider: any FileSystemProvider
    /// 1バッチの最大レコード数
    public let batchSize: Int
    /// 件数が少なくてもバッチを送る間隔
    public let flushInterval: TimeInterval

    public init(
        scope: ScanScope,
        provider: any FileSystemProvider = POSIXFileSystem(),
        batchSize: Int = 1024,
        flushInterval: TimeInterval = 0.1
    ) {
        self.scope = scope
        self.provider = provider
        self.batchSize = max(1, batchSize)
        self.flushInterval = flushInterval
    }

    /// 走査を実行する。
    /// - Parameters:
    ///   - isCancelled: 項目ごとに確認するキャンセル要求
    ///   - deliver: 保存用バッチを受け取る。満杯の場合はここで待たせてよい（バッチを破棄しない）。
    public func run(isCancelled: () -> Bool, deliver: ([ScanRecord]) -> Void) -> ScanTermination {
        withoutActuallyEscaping(deliver) { deliver in
            var emitter = BatchEmitter(batchSize: batchSize, flushInterval: flushInterval, deliver: deliver)
            defer { emitter.flush() }
            return scan(emitter: &emitter, isCancelled: isCancelled)
        }
    }

    private func scan(emitter: inout BatchEmitter, isCancelled: () -> Bool) -> ScanTermination {
        provider.prepareScanningThread()

        let rootPath = scope.rootPath
        let rootID = ItemID(0)
        var nextID: Int32 = 1

        let rootMetadata: FileMetadata
        switch provider.metadata(atPath: rootPath) {
        case .success(let metadata):
            rootMetadata = metadata
        case .failure(let error):
            emitter.emit(.item(DiscoveredItem(
                id: rootID, parentID: nil, name: scope.displayName, kind: .directory,
                accessState: error.accessState, errorDescription: error.message
            )))
            emitter.emit(.directoryListed(rootID, .failed(error.accessState, error.message)))
            return .rootFailed(error)
        }

        // クラウド上だけにあるフォルダは、列挙すると取得が始まるためルートでも開かない
        let rootIsCloudOnly = rootMetadata.kind == .directory && rootMetadata.isDataless
        emitter.emit(.item(DiscoveredItem(
            id: rootID, parentID: nil, name: scope.displayName, kind: rootMetadata.kind,
            isPackage: rootMetadata.mayBePackage,
            logicalSize: rootMetadata.logicalSize, allocatedSize: rootMetadata.allocatedSize,
            modifiedDate: rootMetadata.modifiedDate, createdDate: rootMetadata.createdDate,
            accessState: rootIsCloudOnly ? .notScanned : .readable,
            fileIdentity: rootMetadata.identity,
            errorDescription: rootIsCloudOnly ? "クラウド上にのみあるフォルダです" : nil
        )))
        if rootIsCloudOnly {
            return .rootFailed(FileSystemError(kind: .cloudOnly, code: 0, message: "クラウド上にのみあるフォルダのため、ダウンロードを避けて走査しません"))
        }
        guard rootMetadata.kind == .directory else {
            let error = FileSystemError(kind: .other, code: 0, message: "フォルダではありません")
            return .rootFailed(error)
        }

        var visited = Set<FileIdentity>()
        var allowedDevices = scope.allowedDevices
        if let identity = rootMetadata.identity {
            visited.insert(identity)
            // 指定の有無にかかわらず、選ばれたルート自身のデバイスは常に範囲内
            allowedDevices.insert(identity.device)
        }
        var stack: [(id: ItemID, path: String, identity: FileIdentity?)] = [(rootID, rootPath, rootMetadata.identity)]

        while let directory = stack.popLast() {
            if isCancelled() {
                return .cancelled
            }
            let listing: DirectoryListing
            switch provider.listDirectory(atPath: directory.path, expectedIdentity: directory.identity, isCancelled: isCancelled) {
            case .success(let result):
                listing = result
            case .failure(let error):
                emitter.emit(.directoryListed(directory.id, .failed(error.accessState, error.message)))
                if directory.id == rootID {
                    return .rootFailed(error)
                }
                continue
            }

            for entry in listing.entries {
                if isCancelled() {
                    emitter.emit(.directoryListed(directory.id, .interrupted(nil)))
                    return .cancelled
                }
                let id = ItemID(nextID)
                nextID += 1
                switch entry.metadata {
                case .failure(let error):
                    // 列挙後に消えた・読めない項目。種類もサイズも不明として記録する。
                    emitter.emit(.item(DiscoveredItem(
                        id: id, parentID: directory.id, name: entry.name, kind: .other,
                        accessState: error.accessState, errorDescription: error.message
                    )))
                case .success(let metadata):
                    let path = PathUtilities.join(directory.path, entry.name)
                    let isDirectory = metadata.kind == .directory
                    let exclusion = isDirectory
                        ? exclusionReason(
                            path: path, identity: metadata.identity,
                            allowedDevices: allowedDevices, visited: &visited
                        )
                        : nil
                    // クラウド上だけのフォルダは列挙すると取得が始まるため、未走査として残す
                    let cloudOnly = isDirectory && exclusion == nil && metadata.isDataless
                    emitter.emit(.item(DiscoveredItem(
                        id: id, parentID: directory.id, name: entry.name, kind: metadata.kind,
                        isPackage: metadata.mayBePackage,
                        logicalSize: metadata.logicalSize, allocatedSize: metadata.allocatedSize,
                        modifiedDate: metadata.modifiedDate, createdDate: metadata.createdDate,
                        accessState: cloudOnly ? .notScanned : .readable,
                        fileIdentity: metadata.identity, exclusionReason: exclusion,
                        errorDescription: cloudOnly ? "クラウド上にのみあるフォルダです" : nil
                    )))
                    if isDirectory, exclusion == nil, !cloudOnly {
                        stack.append((id, path, metadata.identity))
                    }
                }
            }
            if let error = listing.error {
                emitter.emit(.directoryListed(directory.id, .interrupted(error.message, access: error.accessState)))
            } else {
                emitter.emit(.directoryListed(directory.id, .complete))
            }
        }
        return isCancelled() ? .cancelled : .finished
    }

    /// 配下のディレクトリに入るかを範囲規則で判定する。ルート自身には適用しない。
    private func exclusionReason(
        path: String,
        identity: FileIdentity?,
        allowedDevices: Set<UInt64>,
        visited: inout Set<FileIdentity>
    ) -> ExclusionReason? {
        if scope.excludedPaths.contains(path) {
            return .scopeRule
        }
        guard let identity else {
            // 識別できない環境では範囲規則だけを守り、根拠なく同一判定しない
            return nil
        }
        if !allowedDevices.isEmpty, !allowedDevices.contains(identity.device) {
            return .otherVolume
        }
        if !visited.insert(identity).inserted {
            return .duplicatePath
        }
        return nil
    }
}

/// レコードを件数または時間でまとめて渡す。
struct BatchEmitter {
    let batchSize: Int
    let flushInterval: TimeInterval
    let deliver: ([ScanRecord]) -> Void
    private var buffer: [ScanRecord] = []
    private var lastFlush = Date()

    init(batchSize: Int, flushInterval: TimeInterval, deliver: @escaping ([ScanRecord]) -> Void) {
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.deliver = deliver
        buffer.reserveCapacity(batchSize)
    }

    mutating func emit(_ record: ScanRecord) {
        buffer.append(record)
        if buffer.count >= batchSize || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    mutating func flush() {
        lastFlush = Date()
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        deliver(batch)
    }
}
