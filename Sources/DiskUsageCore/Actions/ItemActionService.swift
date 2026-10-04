import Foundation

/// macOS のゴミ箱へ移す処理の境界。完全削除へのフォールバックを実装してはならない。
public protocol Trasher: Sendable {
    /// - Returns: ゴミ箱内の移動先パス（取得できれば）
    func moveToTrash(atPath path: String) throws -> String?
}

/// `FileManager.trashItem` による実装。macOS 以外では常に失敗する。
public struct FoundationTrasher: Trasher {
    public init() {}

    public func moveToTrash(atPath path: String) throws -> String? {
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
        #else
        throw TrashFailure.unsupported
        #endif
    }
}

/// 確認済みの移動対象。確認ダイアログに名前・場所・取得済みサイズを示す。
public struct TrashCandidate: Equatable, Sendable {
    public let scanID: ScanID
    public let itemID: ItemID
    public let name: String
    public let path: String
    public let allocatedSize: Int64?
    public let identity: FileIdentity
}

public enum TrashFailure: Error, Equatable, Sendable {
    case blocked(TrashBlockReason)
    /// 確認後に項目が消えた・置き換わった・親の経路が変わった
    case changedSinceScan(String)
    /// ファイルシステムが移動を拒否した
    case systemRefused(String)
    case unsupported

    public var message: String {
        switch self {
        case .blocked(let reason): return reason.message
        case .changedSinceScan(let detail): return "スキャン後に項目が変わったため中止しました（\(detail)）。再スキャンしてから選び直してください。"
        case .systemRefused(let detail): return "ゴミ箱へ移動できませんでした: \(detail)"
        case .unsupported: return "この環境ではゴミ箱へ移動できません。"
        }
    }
}

public struct TrashOutcome: Equatable, Sendable {
    public let candidate: TrashCandidate
    public let trashedPath: String?
}

/// Finder 表示以外のファイル操作（ゴミ箱移動）を、スキャンエンジンから独立して扱う。
///
/// 移動できるのは通常ファイル1件のみ。確認後に種類・識別情報・親経路・保護対象・範囲を
/// 再確認し、変化や識別不能があれば中止する。移動後は結果を古いものとして扱う。
public final class ItemActionService: @unchecked Sendable {
    private let provider: any FileSystemProvider
    private let trasher: any Trasher
    private let policy: TrashPolicy
    private let lock = NSLock()
    private var isBusy = false
    private var moved: [ScanID: Set<ItemID>] = [:]
    private var packageAncestorCache: [String: Bool] = [:]

    public init(
        provider: any FileSystemProvider = POSIXFileSystem(),
        trasher: any Trasher = FoundationTrasher(),
        policy: TrashPolicy = TrashPolicy()
    ) {
        self.provider = provider
        self.trasher = trasher
        self.policy = policy
    }

    public var isOperationInProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isBusy
    }

    public func isMoved(_ id: ItemID, in session: ScanSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return moved[session.scanID]?.contains(id) ?? false
    }

    /// UI でボタンを有効にするかの判定と、確認ダイアログに出す内容。ファイルシステムには触れない
    /// （スキャンルートより上のパッケージ判定だけはキャッシュ付きで確認する）。
    public func candidate(for id: ItemID, in session: ScanSession) -> Result<TrashCandidate, TrashBlockReason> {
        evaluate(id, in: session, ignoringOwnOperation: false)
    }

    private func evaluate(_ id: ItemID, in session: ScanSession, ignoringOwnOperation: Bool) -> Result<TrashCandidate, TrashBlockReason> {
        lock.lock()
        let busy = isBusy && !ignoringOwnOperation
        let alreadyMoved = moved[session.scanID]?.contains(id) ?? false
        lock.unlock()
        if !session.currentState.isTerminal {
            return .failure(.scanNotFinished)
        }
        if busy {
            return .failure(.operationInProgress)
        }
        if alreadyMoved {
            return .failure(.alreadyMoved)
        }
        let store = session.store
        guard let item = store.item(id), let path = store.path(of: id) else {
            return .failure(.notInCurrentResult)
        }
        if item.parentID == nil {
            return .failure(.scanRoot)
        }
        guard item.kind == .file else {
            return .failure(.notRegularFile)
        }
        guard item.accessState == .readable else {
            return .failure(.unreadable)
        }
        guard let identity = item.fileIdentity else {
            return .failure(.identityUnavailable)
        }
        guard PathUtilities.isSafeAbsolute(path) else {
            return .failure(.unsafePath)
        }
        guard PathUtilities.isSameOrDescendant(path, of: session.scope.rootPath), path != session.scope.rootPath else {
            return .failure(.outsideScope)
        }
        if let root = policy.protectedRoot(containing: path) {
            return .failure(.protectedLocation(root))
        }
        let ancestry = store.ancestry(of: id).dropLast()
        if ancestry.contains(where: { store.item($0)?.isPackage ?? true }) {
            return .failure(.insidePackage)
        }
        if hasPackageAboveRoot(session.scope.rootPath) {
            return .failure(.insidePackage)
        }
        return .success(TrashCandidate(
            scanID: session.scanID, itemID: id, name: item.name, path: path,
            allocatedSize: item.allocatedSize, identity: identity
        ))
    }

    /// 確認済みの対象を再確認してからゴミ箱へ移す。失敗しても完全削除はしない。
    public func moveToTrash(_ candidate: TrashCandidate, in session: ScanSession) -> Result<TrashOutcome, TrashFailure> {
        guard candidate.scanID == session.scanID else {
            return .failure(.blocked(.notInCurrentResult))
        }
        lock.lock()
        if isBusy {
            lock.unlock()
            return .failure(.blocked(.operationInProgress))
        }
        isBusy = true
        lock.unlock()
        defer {
            lock.lock()
            isBusy = false
            lock.unlock()
        }

        // 確認ダイアログの間に状態や判定材料が変わっていないかを最初からやり直す
        switch evaluate(candidate.itemID, in: session, ignoringOwnOperation: true) {
        case .failure(let reason):
            return .failure(.blocked(reason))
        case .success(let fresh) where fresh != candidate:
            return .failure(.changedSinceScan("結果の内容が変わりました"))
        case .success:
            break
        }

        if let problem = verifyOnDisk(candidate, in: session) {
            return .failure(.changedSinceScan(problem))
        }

        do {
            let trashedPath = try trasher.moveToTrash(atPath: candidate.path)
            lock.lock()
            moved[session.scanID, default: []].insert(candidate.itemID)
            lock.unlock()
            session.markStale()
            return .success(TrashOutcome(candidate: candidate, trashedPath: trashedPath))
        } catch let failure as TrashFailure {
            return .failure(failure)
        } catch {
            return .failure(.systemRefused(error.localizedDescription))
        }
    }

    /// 対象と、ルートから親までの各ディレクトリが、スキャン時と同じ実体のままかを lstat で確かめる。
    private func verifyOnDisk(_ candidate: TrashCandidate, in session: ScanSession) -> String? {
        let store = session.store
        for ancestorID in store.ancestry(of: candidate.itemID).dropLast() {
            guard let ancestor = store.item(ancestorID),
                  let path = store.path(of: ancestorID),
                  let expected = ancestor.fileIdentity else {
                return "親フォルダを識別できません"
            }
            switch provider.metadata(atPath: path) {
            case .failure(let error):
                return "親フォルダを確認できません: \(error.message)"
            case .success(let metadata):
                guard metadata.kind == .directory else {
                    return "親フォルダがフォルダではなくなりました: \(path)"
                }
                guard metadata.identity == expected else {
                    return "親フォルダが置き換わりました: \(path)"
                }
            }
        }
        switch provider.metadata(atPath: candidate.path) {
        case .failure(let error):
            return "項目を確認できません: \(error.message)"
        case .success(let metadata):
            guard metadata.kind == .file else {
                return "通常ファイルではなくなりました"
            }
            guard metadata.identity == candidate.identity else {
                return "別の項目に置き換わりました"
            }
        }
        return nil
    }

    /// スキャンルートより上の祖先にパッケージがあるか。判定できない場合は安全側（true）に倒す。
    private func hasPackageAboveRoot(_ rootPath: String) -> Bool {
        lock.lock()
        if let cached = packageAncestorCache[rootPath] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var result = false
        var cursor = PathUtilities.parent(of: rootPath)
        while let path = cursor {
            switch provider.metadata(atPath: path) {
            case .success(let metadata):
                if metadata.isPackage {
                    result = true
                }
            case .failure:
                result = true
            }
            if result {
                break
            }
            cursor = PathUtilities.parent(of: path)
        }
        lock.lock()
        packageAncestorCache[rootPath] = result
        lock.unlock()
        return result
    }
}
