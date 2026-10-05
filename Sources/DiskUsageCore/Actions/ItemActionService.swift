import Foundation

/// macOS のゴミ箱へ移す処理の境界。完全削除へのフォールバックを実装してはならない。
public protocol Trasher: Sendable {
    /// - Returns: ゴミ箱内の移動先パス（取得できれば）
    func moveToTrash(atPath path: String) throws -> String?
}

/// `FileManager.trashItem` による実装。macOS 以外では常に失敗する。
///
/// パスを再解決している間に別の項目へ置き換わる余地を減らすため、確認済みの項目を
/// ファイル参照 URL（オブジェクト ID による参照）に変換してから移動する。
public struct FoundationTrasher: Trasher {
    public init() {}

    public func moveToTrash(atPath path: String) throws -> String? {
        #if os(macOS)
        let pathURL = URL(fileURLWithPath: path)
        let target = (pathURL as NSURL).fileReferenceURL() ?? pathURL
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &resulting)
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
    /// 移動はできたが、ゴミ箱に入った項目が確認した項目と一致しない
    case unexpectedItemMoved(String?)
    case unsupported

    public var message: String {
        switch self {
        case .blocked(let reason): return reason.message
        case .changedSinceScan(let detail): return "スキャン後に項目が変わったため中止しました（\(detail)）。再スキャンしてから選び直してください。"
        case .systemRefused(let detail): return "ゴミ箱へ移動できませんでした: \(detail)"
        case .unexpectedItemMoved(let path): return "ゴミ箱へ移動した項目が、確認した項目と一致しません。ゴミ箱（\(path ?? "場所不明")）を確認し、必要なら元に戻してください。"
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
/// スキャンとの排他は `ScanCoordinator` のファイル操作ゲートで行う。
public final class ItemActionService: @unchecked Sendable {
    private let coordinator: ScanCoordinator
    private let provider: any FileSystemProvider
    private let trasher: any Trasher
    private let policy: TrashPolicy
    private let lock = NSLock()
    private var moved: [ScanID: Set<ItemID>] = [:]
    private var packageAncestorCache: [String: Bool] = [:]

    public init(
        coordinator: ScanCoordinator,
        provider: any FileSystemProvider = POSIXFileSystem(),
        trasher: any Trasher = FoundationTrasher(),
        policy: TrashPolicy = TrashPolicy()
    ) {
        self.coordinator = coordinator
        self.provider = provider
        self.trasher = trasher
        self.policy = policy
    }

    public var isOperationInProgress: Bool {
        coordinator.isFileOperationInProgress
    }

    public func isMoved(_ id: ItemID, in session: ScanSession) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return moved[session.scanID]?.contains(id) ?? false
    }

    /// UI でボタンを有効にするかの判定と、確認ダイアログに出す内容。
    public func candidate(for id: ItemID, in session: ScanSession) -> Result<TrashCandidate, TrashBlockReason> {
        evaluate(id, in: session, duringOwnOperation: false, freshPackageCheck: false)
    }

    private func evaluate(
        _ id: ItemID,
        in session: ScanSession,
        duringOwnOperation: Bool,
        freshPackageCheck: Bool
    ) -> Result<TrashCandidate, TrashBlockReason> {
        if !session.currentState.isTerminal {
            return .failure(.scanNotFinished)
        }
        if !coordinator.isCurrentAndFinished(session) {
            return .failure(.notInCurrentResult)
        }
        if !duringOwnOperation, coordinator.isFileOperationInProgress {
            return .failure(.operationInProgress)
        }
        if isMoved(id, in: session) {
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
        if hasPackageAboveRoot(session.scope.rootPath, useCache: !freshPackageCheck) {
            return .failure(.insidePackage)
        }
        if case .success(let metadata) = provider.metadata(atPath: path), (metadata.linkCount ?? 1) > 1 {
            return .failure(.multipleHardLinks)
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
        guard coordinator.beginFileOperation(on: session) else {
            if !coordinator.isCurrentAndFinished(session) {
                return .failure(.blocked(session.currentState.isTerminal ? .notInCurrentResult : .scanNotFinished))
            }
            return .failure(.blocked(.operationInProgress))
        }
        defer { coordinator.endFileOperation() }

        // 確認ダイアログの間に状態や判定材料が変わっていないかを最初からやり直す
        switch evaluate(candidate.itemID, in: session, duringOwnOperation: true, freshPackageCheck: true) {
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

        let trashedPath: String?
        do {
            trashedPath = try trasher.moveToTrash(atPath: candidate.path)
        } catch let failure as TrashFailure {
            return .failure(failure)
        } catch {
            return .failure(.systemRefused(error.localizedDescription))
        }

        lock.lock()
        moved[session.scanID, default: []].insert(candidate.itemID)
        lock.unlock()
        session.markStale()

        // ゴミ箱に入った項目が確認した項目と同じかを確かめる（取り違えを利用者に知らせる）
        if let trashedPath {
            switch provider.metadata(atPath: trashedPath) {
            case .success(let metadata) where metadata.identity != candidate.identity:
                return .failure(.unexpectedItemMoved(trashedPath))
            default:
                break
            }
        }
        return .success(TrashOutcome(candidate: candidate, trashedPath: trashedPath))
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
        guard let item = store.item(candidate.itemID) else {
            return "結果から項目が見つかりません"
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
            guard (metadata.linkCount ?? 1) <= 1 else {
                return "ハードリンクが作られました"
            }
            guard metadata.logicalSize == item.logicalSize, metadata.modifiedDate == item.modifiedDate else {
                return "内容が更新されました"
            }
        }
        return nil
    }

    /// スキャンルートより上の祖先にパッケージがあるか。判定できない場合は安全側（true）に倒す。
    private func hasPackageAboveRoot(_ rootPath: String, useCache: Bool) -> Bool {
        if useCache {
            lock.lock()
            let cached = packageAncestorCache[rootPath]
            lock.unlock()
            if let cached {
                return cached
            }
        }
        var result = false
        var cursor = PathUtilities.parent(of: rootPath)
        while let path = cursor, !result {
            switch provider.metadata(atPath: path) {
            case .success(let metadata):
                result = metadata.mayBePackage
            case .failure:
                result = true
            }
            cursor = PathUtilities.parent(of: path)
        }
        lock.lock()
        packageAncestorCache[rootPath] = result
        lock.unlock()
        return result
    }
}
