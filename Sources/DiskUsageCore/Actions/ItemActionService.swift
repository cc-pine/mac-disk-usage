import Foundation

/// 移動対象への参照。確認の前に作り、確認した実体を指したまま移動に使う。
public struct TrashTarget: Sendable {
    public let path: String
    public let url: URL

    public init(path: String, url: URL) {
        self.path = path
        self.url = url
    }
}

/// macOS のゴミ箱へ移す処理の境界。完全削除へのフォールバックを実装してはならない。
public protocol Trasher: Sendable {
    /// 再確認の前に呼び、パスを現在の実体への参照に変える。
    func target(forPath path: String) -> TrashTarget
    /// 参照が現在指している項目のパス。解決できなければ nil。
    func currentPath(of target: TrashTarget) -> String?
    /// - Returns: ゴミ箱内の移動先パス（取得できれば）
    func moveToTrash(_ target: TrashTarget) throws -> String?
}

extension Trasher {
    public func target(forPath path: String) -> TrashTarget {
        TrashTarget(path: path, url: URL(fileURLWithPath: path))
    }

    public func currentPath(of target: TrashTarget) -> String? {
        target.path
    }
}

/// `FileManager.trashItem` による実装。macOS 以外では常に失敗する。
///
/// 再確認と移動の間にパスが別の項目へ置き換わる余地を減らすため、再確認の前に
/// ファイル参照 URL（オブジェクト ID による参照）を作り、それを移動に使う。
/// 参照を作れない場合はパスの URL を使い、移動後の識別情報の確認で取り違えを知らせる。
public struct FoundationTrasher: Trasher {
    public init() {}

    public func target(forPath path: String) -> TrashTarget {
        let pathURL = URL(fileURLWithPath: path)
        #if os(macOS)
        if let reference = (pathURL as NSURL).fileReferenceURL() {
            return TrashTarget(path: path, url: reference)
        }
        #endif
        return TrashTarget(path: path, url: pathURL)
    }

    public func currentPath(of target: TrashTarget) -> String? {
        #if os(macOS)
        // ファイル参照 URL なら、いま指している項目のパスへ解決する
        if let resolved = (target.url as NSURL).filePathURL {
            return PathUtilities.normalize(resolved.path)
        }
        return nil
        #else
        return target.path
        #endif
    }

    public func moveToTrash(_ target: TrashTarget) throws -> String? {
        #if os(macOS)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: target.url, resultingItemURL: &resulting)
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
    /// 移動の前に、対象や経路を読み取れず確認できなかった
    case cannotVerify(String)
    /// 移動はできたが、ゴミ箱に入った項目が確認した項目と一致しない、または元の場所に残っている
    case unexpectedItemMoved(String?)
    case unsupported

    public var message: String {
        switch self {
        case .blocked(let reason): return reason.message
        case .changedSinceScan(let detail): return "スキャン後に項目が変わったため中止しました（\(detail)）。再スキャンしてから選び直してください。"
        case .systemRefused(let detail): return detail
        case .cannotVerify(let detail): return "移動前に項目を確認できなかったため、中止しました。詳細: \(detail)"
        case .unexpectedItemMoved(let path): return "選んだ項目がゴミ箱へ移動したことを確認できませんでした。元の場所に残っているか、別の項目が移動した可能性があります。ゴミ箱（\(path ?? "場所不明")）と元の場所を確認し、必要に応じて元に戻してください。"
        case .unsupported: return "この環境ではゴミ箱へ移動できません。"
        }
    }
}

public struct TrashOutcome: Equatable, Sendable {
    public let candidate: TrashCandidate
    public let trashedPath: String?
    /// ゴミ箱内の項目が確認した項目と同じ実体だと確かめられたか（移動先を読めない場合は false）
    public let isVerified: Bool
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
        if let root = policy.protectedRoot(containing: path, volumeRoots: volumeRoots(above: id, in: session)) {
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

        // 参照は再確認の前に作り、確認した実体を指したまま移動に使う
        let target = trasher.target(forPath: candidate.path)
        if let problem = verifyOnDisk(candidate, in: session) {
            return .failure(problem)
        }
        // 参照が、確認した場所の項目を指したままかを確かめる（参照を作った後で差し替わっていないか）
        guard trasher.currentPath(of: target) == candidate.path else {
            return .failure(.changedSinceScan("移動の参照先が確認した項目と一致しません"))
        }

        let trashedPath: String?
        do {
            trashedPath = try trasher.moveToTrash(target)
        } catch let failure as TrashFailure {
            return .failure(failure)
        } catch {
            return .failure(.systemRefused(error.localizedDescription))
        }

        // 元の場所を確かめる。確認した実体がまだ残っていれば、別の項目が移動された可能性がある
        let originVacated: Bool
        switch provider.metadata(atPath: candidate.path) {
        case .success(let metadata) where metadata.identity == candidate.identity:
            originVacated = false
        default:
            originVacated = true
        }
        if originVacated {
            lock.lock()
            moved[session.scanID, default: []].insert(candidate.itemID)
            lock.unlock()
        }
        // 何かがゴミ箱へ移った可能性があるため、どちらの場合も結果は古いものとして扱う
        session.markStale()
        guard originVacated else {
            return .failure(.unexpectedItemMoved(trashedPath))
        }

        // ゴミ箱に入った項目が確認した項目と同じかを確かめる（取り違えを利用者に知らせる）。
        // 移動先を読めない（~/.Trash へのアクセスが制限されているなど）場合は「未確認」として返す。
        // 移動で inode が変わるファイルシステム（FAT など）では、サイズと更新日時が一致すれば未確認とする
        // （名前はゴミ箱内で重複を避けるため変わることがあるので比べない）。
        var isVerified = false
        if let trashedPath, case .success(let metadata) = provider.metadata(atPath: trashedPath) {
            if metadata.identity == candidate.identity {
                isVerified = true
            } else if let item = session.store.item(candidate.itemID),
                      metadata.kind == .file,
                      metadata.logicalSize == item.logicalSize,
                      metadata.modifiedDate == item.modifiedDate {
                isVerified = false
            } else {
                return .failure(.unexpectedItemMoved(trashedPath))
            }
        }
        return .success(TrashOutcome(candidate: candidate, trashedPath: trashedPath, isVerified: isVerified))
    }

    /// 移動の直前に、対象と経路がスキャン時と同じ実体のままかを lstat で確かめる。
    ///
    /// - スキャンルートより上の各フォルダがリンクに置き換わっていない（ツリーごと移されていない）
    /// - ルートから親までの各フォルダの識別情報が変わっていない
    /// - 対象が同じ実体の通常ファイルで、ハードリンクがなく、内容が更新されていない
    private func verifyOnDisk(_ candidate: TrashCandidate, in session: ScanSession) -> TrashFailure? {
        let store = session.store
        func unreadable(_ what: String, _ error: FileSystemError) -> TrashFailure {
            error.kind == .notFound
                ? .changedSinceScan("\(what)が見つかりません")
                : .cannotVerify("\(what)を確認できません: \(error.message)")
        }

        var cursor = PathUtilities.parent(of: session.scope.rootPath)
        while let path = cursor, path != "/" {
            switch provider.metadata(atPath: path) {
            case .failure(let error):
                return unreadable("スキャン対象より上のフォルダ", error)
            case .success(let metadata) where metadata.kind != .directory:
                return .changedSinceScan("スキャン対象より上のフォルダがフォルダではなくなりました: \(path)")
            case .success:
                break
            }
            cursor = PathUtilities.parent(of: path)
        }

        for ancestorID in store.ancestry(of: candidate.itemID).dropLast() {
            guard let ancestor = store.item(ancestorID),
                  let path = store.path(of: ancestorID),
                  let expected = ancestor.fileIdentity else {
                return .cannotVerify("親フォルダを識別できません")
            }
            switch provider.metadata(atPath: path) {
            case .failure(let error):
                return unreadable("親フォルダ", error)
            case .success(let metadata):
                guard metadata.kind == .directory else {
                    return .changedSinceScan("親フォルダがフォルダではなくなりました: \(path)")
                }
                guard metadata.identity == expected else {
                    return .changedSinceScan("親フォルダが置き換わりました: \(path)")
                }
            }
        }
        guard let item = store.item(candidate.itemID) else {
            return .cannotVerify("結果から項目が見つかりません")
        }
        switch provider.metadata(atPath: candidate.path) {
        case .failure(let error):
            return unreadable("項目", error)
        case .success(let metadata):
            guard metadata.kind == .file else {
                return .changedSinceScan("通常ファイルではなくなりました")
            }
            guard metadata.identity == candidate.identity else {
                return .changedSinceScan("別の項目に置き換わりました")
            }
            guard (metadata.linkCount ?? 1) <= 1 else {
                return .changedSinceScan("ハードリンクが作られました")
            }
            guard metadata.logicalSize == item.logicalSize, metadata.modifiedDate == item.modifiedDate else {
                return .changedSinceScan("内容が更新されました")
            }
        }
        return nil
    }

    /// 項目より上にあるボリュームのマウント先（親とデバイスが異なるフォルダ）。
    /// `/Volumes` 以外にマウントされたボリュームにもボリューム単位の保護規則を当てるために使う。
    /// スキャンルートより上（ルートを含む）は lstat で、ルートより下はスキャン結果の識別情報で調べる。
    ///
    /// 起動ディスクでは firmlink 先（`/Users`、`/Volumes` など Data 側）もデバイスが変わるため
    /// マウント先として扱い、その直下の `System`・`Library` などの名前のフォルダも保護対象になる。
    /// 禁止が広がる方向の誤りなので許容する。
    private func volumeRoots(above id: ItemID, in session: ScanSession) -> [String] {
        let store = session.store
        var roots: [String] = []
        var parentDevice: UInt64?
        let rootComponents = PathUtilities.components(of: session.scope.rootPath)
        for depth in 0..<rootComponents.count {
            let path = "/" + rootComponents.prefix(depth + 1).joined(separator: "/")
            guard case .success(let metadata) = provider.metadata(atPath: path), let device = metadata.identity?.device else {
                parentDevice = nil
                continue
            }
            if depth == 0, case .success(let root) = provider.metadata(atPath: "/") {
                parentDevice = root.identity?.device
            }
            if let parentDevice, parentDevice != device {
                roots.append(path)
            }
            parentDevice = device
        }
        for ancestorID in store.ancestry(of: id).dropLast().dropFirst() {
            guard let device = store.item(ancestorID)?.fileIdentity?.device else { continue }
            if let parentDevice, parentDevice != device, let path = store.path(of: ancestorID) {
                roots.append(path)
            }
            parentDevice = device
        }
        return roots
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
