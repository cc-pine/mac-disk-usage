import Foundation

/// 画面の言語。日本語と英語に対応する。
public enum AppLanguage: String, Sendable, CaseIterable {
    case japanese = "ja"
    case english = "en"

    /// 優先言語を順に見て、最初に現れた対応言語（日本語・英語）を選ぶ。macOS がメニューなどの
    /// 言語を選ぶ規則と揃える。どちらも含まれなければ英語。
    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for language in languages.map({ $0.lowercased() }) {
            if language.hasPrefix("ja") { return .japanese }
            if language.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// 画面に出す文言の対訳表。日本語と英語を同じ行に並べ、片方の訳の抜けを防ぐ。
///
/// 言語はアプリの起動時に決まる `L10n.language` に従う。テストでは明示的に設定する。
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLanguage = AppLanguage.preferred()

    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedLanguage
        }
        set {
            lock.lock()
            storedLanguage = newValue
            lock.unlock()
        }
    }

    static func t(_ ja: String, _ en: String) -> String {
        language == .japanese ? ja : en
    }

    private static func count(_ value: Int) -> String {
        value.formatted()
    }

    // MARK: - 容量と状態

    public static var unknown: String { t("不明", "Unknown") }
    public static func byteCount(_ value: Int64) -> String { t("\(value) バイト", value == 1 ? "1 byte" : "\(value) bytes") }
    public static func incomplete(_ text: String) -> String { t("\(text)・一部未取得", "\(text) (incomplete)") }
    public static var notCounted: String { t("—（集計対象外）", "— (not counted)") }
    public static var excluded: String { t("除外", "Excluded") }
    public static func excluded(because reason: String) -> String { t("除外（\(reason)）", "Excluded (\(reason))") }

    public static var kindFile: String { t("ファイル", "File") }
    public static var kindFolder: String { t("フォルダ", "Folder") }
    public static var kindPackage: String { t("パッケージ", "Package") }
    public static var kindSymbolicLink: String { t("シンボリックリンク", "Symbolic link") }
    public static var kindSpecialFile: String { t("特殊ファイル", "Special file") }

    public static var accessReadable: String { t("読み取り可", "Readable") }
    public static var accessDenied: String { t("アクセス拒否", "Access denied") }
    public static var accessError: String { t("読み取りエラー", "Read error") }
    public static var accessNotScanned: String { t("未走査", "Not scanned") }
    public static var accessNotScannedCloud: String { t("未走査（クラウド上のみで一覧を取得できないなど）", "Not scanned (for example, a cloud-only folder that couldn’t be listed)") }
    public static var traversalScanning: String { t("スキャン中", "Scanning") }
    public static var traversalPartial: String { t("一部のみ走査", "Partially scanned") }
    public static var listSeparator: String { t("・", " · ") }

    public static var exclusionOtherVolume: String { t("別のボリューム", "Other volume") }
    public static var exclusionDuplicatePath: String { t("別経路", "Alternate path") }
    public static var exclusionScopeRule: String { t("範囲規則", "Scope rule") }

    public static var stateNotScanned: String { t("未スキャン", "Not scanned") }
    public static var stateScanning: String { t("スキャン中（部分結果）", "Scanning (partial results)") }
    public static var stateCancelling: String { t("中止しています…", "Stopping…") }
    public static var stateCompleted: String { t("完了", "Completed") }
    public static var stateCompletedWithErrors: String { t("完了（一部未取得）", "Completed (some information missing)") }
    public static var stateCancelled: String { t("中止（部分結果）", "Stopped (partial results)") }
    public static var stateFailed: String { t("失敗", "Failed") }
    public static func stale(_ state: String) -> String { t("\(state)・結果が古くなっています", "\(state) — results are out of date") }

    public static func timeRange(_ start: String, _ end: String) -> String { t("\(start)〜\(end)", "\(start)–\(end)") }
    public static func seconds(_ value: Int) -> String { t("\(value)秒", "\(value) s") }
    public static func minutesSeconds(_ minutes: Int, _ seconds: Int) -> String { t("\(minutes)分\(seconds)秒", "\(minutes) min \(seconds) s") }

    // MARK: - ファイルシステムのエラー

    public static func withErrno(_ text: String, _ code: Int32) -> String { t("\(text)（errno \(code)）", "\(text) (errno \(code))") }
    public static var errorNoLongerFolder: String { t("フォルダではなくなりました", "It is no longer a folder") }
    public static var errorReplacedDuringScan: String { t("走査中に別の項目へ置き換わりました", "It was replaced by another item during the scan") }
    public static var errorPermissionDenied: String { t("アクセスが拒否されました", "Access was denied") }
    public static var errorNotFound: String { t("見つかりません。走査中に移動・削除された可能性があります", "Not found. It may have been moved or deleted during the scan") }
    public static var errorCloudOnlyItem: String { t("クラウド上にのみあり、一覧を取得できませんでした", "This item is only in the cloud, and its contents couldn’t be listed") }
    public static var errorPathTooLong: String { t("パスが長すぎるため読み取れません", "The path is too long to read") }
    public static var errorDiskIO: String { t("ディスクの読み取りでエラーが起きました", "An error occurred while reading the disk") }
    public static var errorTimedOut: String { t("応答がないため読み取れませんでした", "Could not read because there was no response") }
    public static func errorReadFailed(_ detail: String) -> String { t("読み取りに失敗しました: \(detail)", "Read failed: \(detail)") }
    public static var errorNotAFolder: String { t("フォルダではありません", "It is not a folder") }

    // MARK: - ゴミ箱へ移動できない理由

    public static var trashScanNotFinished: String { t("スキャン中と、スキャンの中止処理中は移動できません。", "Items can’t be moved while a scan is running or stopping.") }
    public static var trashOperationInProgress: String { t("別のゴミ箱操作を実行中です。", "Another move to the Trash is in progress.") }
    public static var trashNotRegularFile: String { t("移動できるのは通常のファイルだけです。", "Only regular files can be moved.") }
    public static var trashUnreadable: String { t("項目を読み取れなかったため移動できません。", "The item couldn’t be read, so it can’t be moved.") }
    public static var trashScanRoot: String { t("スキャン対象そのものは移動できません。", "The scanned location itself can’t be moved.") }
    public static func trashProtected(_ root: String) -> String { t("保護された場所（\(root)）の項目は移動できません。", "Items in a protected location (\(root)) can’t be moved.") }
    public static var trashInsidePackage: String { t("アプリなどのパッケージ内部の項目は移動できません。", "Items inside an app or other package can’t be moved.") }
    public static var trashOutsideScope: String { t("スキャン範囲外の項目は移動できません。", "Items outside the scanned location can’t be moved.") }
    public static var trashUnsafePath: String { t("場所を安全に確認できないため移動できません。", "The location can’t be verified safely, so the item can’t be moved.") }
    public static var trashIdentityUnavailable: String { t("項目を識別できないため移動できません。", "The item can’t be identified, so it can’t be moved.") }
    public static var trashMultipleHardLinks: String { t("ほかの場所からも参照されている（ハードリンクがある）ファイルは移動できません。", "Files that are also referenced from other locations (hard links) can’t be moved.") }
    public static var trashAlreadyMoved: String { t("この項目は移動済みです。", "This item has already been moved.") }
    public static var trashNotInCurrentResult: String { t("現在のスキャン結果に含まれない項目です。", "This item isn’t in the current scan results.") }

    // MARK: - ゴミ箱へ移動した結果

    public static func trashChangedSinceScan(_ detail: String) -> String {
        t("スキャン後に項目が変わったため中止しました（\(detail)）。再スキャンしてから選び直してください。",
          "The item wasn’t moved because it changed after the scan (\(detail)). Scan again, then reselect the item.")
    }
    public static func trashCannotVerify(_ detail: String) -> String {
        t("移動前に項目を確認できなかったため、中止しました。詳細: \(detail)",
          "The item wasn’t moved because it couldn’t be verified first. Details: \(detail)")
    }
    public static func trashUnexpectedItemMoved(_ path: String?) -> String {
        let location = path ?? t("場所不明", "unknown location")
        return t("選んだ項目がゴミ箱へ移動したことを確認できませんでした。元の場所に残っているか、別の項目が移動した可能性があります。ゴミ箱（\(location)）と元の場所を確認し、必要に応じて元に戻してください。",
                 "Couldn’t confirm that the selected item was moved to the Trash. It may still be in its original location, or a different item may have been moved. Check the Trash (\(location)) and the original location, and put items back if needed.")
    }
    public static var trashUnsupported: String { t("この環境ではゴミ箱へ移動できません。", "Moving to the Trash isn’t supported here.") }

    public static var verifyResultChanged: String { t("結果の内容が変わりました", "the scan results changed") }
    public static var verifyReferenceMismatch: String { t("移動の参照先が確認した項目と一致しません", "the item to move no longer matches the confirmed item") }
    public static func verifyNotFound(_ what: String) -> String { t("\(what)が見つかりません", "\(what) wasn’t found") }
    public static func verifyCannotCheck(_ what: String, _ detail: String) -> String { t("\(what)を確認できません: \(detail)", "couldn’t check \(what): \(detail)") }
    public static var verifyFolderAboveRoot: String { t("スキャン対象より上のフォルダ", "a folder above the scanned location") }
    public static func verifyFolderAboveRootNotFolder(_ path: String) -> String { t("スキャン対象より上のフォルダがフォルダではなくなりました: \(path)", "a folder above the scanned location is no longer a folder: \(path)") }
    public static var verifyParentUnidentified: String { t("親フォルダを識別できません", "the parent folder can’t be identified") }
    public static var verifyParentFolder: String { t("親フォルダ", "the parent folder") }
    public static func verifyParentNotFolder(_ path: String) -> String { t("親フォルダがフォルダではなくなりました: \(path)", "the parent folder is no longer a folder: \(path)") }
    public static func verifyParentReplaced(_ path: String) -> String { t("親フォルダが置き換わりました: \(path)", "the parent folder was replaced: \(path)") }
    public static var verifyItemMissingFromResult: String { t("結果から項目が見つかりません", "the item isn’t in the results") }
    public static var verifyItem: String { t("項目", "the item") }
    public static var verifyNoLongerFile: String { t("通常ファイルではなくなりました", "it is no longer a regular file") }
    public static var verifyReplaced: String { t("別の項目に置き換わりました", "it was replaced by another item") }
    public static var verifyHardLinkCreated: String { t("ハードリンクが作られました", "a hard link was created") }
    public static var verifyContentChanged: String { t("内容が更新されました", "its contents changed") }

    // MARK: - アプリ: 全般

    public static var appTitle: String { t("ディスク使用量", "Disk Usage") }
    public static var ok: String { "OK" }
    public static var cancel: String { t("キャンセル", "Cancel") }
    public static var close: String { t("閉じる", "Close") }
    public static var previous: String { t("前へ", "Previous") }
    public static var next: String { t("次へ", "Next") }
    public static var previousPage: String { t("前のページ", "Previous page") }
    public static var nextPage: String { t("次のページ", "Next page") }
    public static func pageRange(from: Int, to: Int, total: Int) -> String {
        t("\(count(from))〜\(count(to)) 件目 / \(count(total)) 件", "\(count(from))–\(count(to)) of \(count(total))")
    }

    // MARK: - アプリ: メニュー

    public static var menuScan: String { t("スキャン", "Scan") }
    public static var menuStopScan: String { t("スキャンを中止", "Stop Scan") }
    public static var menuGo: String { t("移動", "Go") }
    public static var menuOpenSelection: String { t("選択項目を開く", "Open Selected Item") }
    public static var menuParentFolder: String { t("親フォルダへ", "Enclosing Folder") }
    public static var menuShowInFolder: String { t("フォルダ内で表示", "Show in Enclosing Folder") }
    public static var menuShowInFinder: String { t("Finder で表示", "Show in Finder") }

    // MARK: - アプリ: 開始画面

    public static var sectionVolumes: String { t("ボリューム", "Volumes") }
    public static var sectionFolder: String { t("フォルダ", "Folder") }
    public static var chooseFolder: String { t("フォルダを選択…", "Choose Folder…") }
    public static func target(_ name: String) -> String { t("対象: \(name)", "Selected: \(name)") }
    public static var scan: String { t("スキャン", "Scan") }
    public static var scanAnotherTarget: String { t("対象を変えてスキャン", "Scan Selected Location") }
    public static var scanHelp: String { t("選んだ対象をスキャンします", "Scans the selected location") }
    public static var scanAnotherTargetHelp: String { t("実行中のスキャンを中止してから、選んだ対象をスキャンします", "Stops the current scan, then scans the selected location") }
    public static var waitingForPreviousScan: String { t("前のスキャンの停止を待っています…", "Waiting for the previous scan to stop…") }
    public static var reloadVolumes: String { t("ボリュームを再読み込み", "Reload Volumes") }
    public static var reloadVolumesHelp: String { t("ボリューム一覧と容量情報を更新します", "Updates the volume list and capacity information") }
    public static var capacityUnavailable: String { t("容量情報を取得できません", "Capacity information unavailable") }
    public static func used(_ bytes: String) -> String { t("使用 \(bytes)", "\(bytes) used") }
    public static var usedUnknown: String { t("使用量不明", "usage unknown") }
    public static func available(_ bytes: String) -> String { t("空き \(bytes)", "\(bytes) available") }
    public static var availableUnknown: String { t("空き容量不明", "available space unknown") }
    public static func volumeRow(used: String, total: String, available: String, time: String) -> String {
        t("\(used) / 全体 \(total)・\(available)（\(time) 時点）", "\(total) total — \(used), \(available) (as of \(time))")
    }

    // MARK: - アプリ: 全体の画面

    public static var chooseTarget: String { t("スキャン対象を選択してください", "Select a Volume or Folder to Scan") }
    public static var chooseTargetDetail: String { t("左の一覧からボリュームまたはフォルダを選択し、「スキャン」をクリックします。", "Select a volume or folder in the sidebar, then click Scan.") }
    public static var details: String { t("詳細", "Details") }
    public static var detailsHelp: String { t("詳細パネルの表示を切り替えます", "Shows or hides the details panel") }
    public static var switchScanTitle: String { t("実行中のスキャンを中止して、選んだ対象をスキャンしますか？", "Stop the current scan and scan the selected location?") }
    public static var switchScanConfirm: String { t("中止してスキャン", "Stop and Scan") }
    public static var switchScanKeep: String { t("スキャンを続ける", "Keep Scanning") }
    public static var switchScanDetail: String { t("ここまでの結果は破棄され、新しい対象の結果に置き換わります。", "The results so far will be discarded and replaced by the results for the new location.") }
    public static var trashConfirmTitle: String { t("ゴミ箱へ移動しますか？", "Move to Trash?") }
    public static var trashConfirmButton: String { t("ゴミ箱へ移動", "Move to Trash") }
    public static func trashConfirmMessage(name: String, path: String, size: String) -> String {
        t("""
          名前: \(name)
          場所: \(path)
          割り当て済みサイズ: \(size)

          ゴミ箱へ移動するだけで、項目は完全には削除されません。空き容量がこのサイズ分増えるとは限りません。
          """,
          """
          Name: \(name)
          Location: \(path)
          Allocated size: \(size)

          The item is only moved to the Trash and is not permanently deleted. Available space may not increase by this amount.
          """)
    }

    // MARK: - アプリ: 結果画面

    public static var viewPicker: String { t("表示", "View") }
    public static var tabList: String { t("一覧", "List") }
    public static var tabTreemap: String { t("ツリーマップ", "Treemap") }
    public static var tabLargeFiles: String { t("大きなファイル", "Large Files") }
    public static func scanTotal(_ size: String) -> String { t("走査集計: \(size)", "Scanned total: \(size)") }
    public static func volumeUsage(used: String?, total: String) -> String {
        guard let used else { return t("ボリューム: 使用量不明 / 全体 \(total)", "Volume: \(total) total, usage unknown") }
        return t("ボリューム: 使用 \(used) / 全体 \(total)", "Volume: \(used) used of \(total)")
    }
    public static func volumeAvailable(_ bytes: String, time: String) -> String { t("空き \(bytes)（\(time) 時点）", "\(bytes) available (as of \(time))") }
    public static var volumeCapacityUnavailable: String { t("ボリューム容量情報を取得できません", "Volume capacity information unavailable") }
    public static var explainDifference: String { t("集計とボリューム使用量の違い", "Why Totals Differ") }
    public static func scanFailed(_ reason: String) -> String { t("スキャンできませんでした。理由: \(reason)", "The scan couldn’t be completed. Reason: \(reason)") }
    public static var forceStoppedBanner: String { t("停止の確認を待たずに中止しました。表示中の結果は中止した時点までのものです。応答しない場所（ネットワーク上のフォルダなど）を走査していた可能性があります。", "The scan was stopped without waiting for it to finish. Results show what was found up to that point. A location that isn’t responding, such as a network folder, may have been blocking the scan.") }
    public static var missingInfoBanner: String { t("情報を取得できなかった場所があります（アクセス拒否・読み取りエラー・クラウド上のみの項目など）。画面下の「未取得」から確認できます。", "Some information couldn’t be read (access denied, read errors, cloud-only items, and so on). See “Missing” at the bottom of the window.") }
    public static var staleBanner: String { t("ゴミ箱へ移動した項目があります。表示中の容量は移動前のものです。最新の容量は再スキャンで確認してください。", "Some items were moved to the Trash. The sizes shown are from before the move. Scan again to see current sizes.") }
    public static var explanationTitle: String { t("走査集計はボリュームの使用量と一致しないことがあります", "The scanned total may differ from volume usage") }
    public static var explanationUnread: String { t("・読み取れなかった場所や、除外した場所（別ボリューム・別経路など）は集計に含まれません。", "• Locations that couldn’t be read and excluded locations (other volumes, alternate paths, and so on) aren’t included.") }
    public static var explanationClones: String { t("・APFS のクローンやハードリンクは共有ブロックを区別せず、パスごとに数えます。", "• APFS clones and hard links are counted per path, without separating shared blocks.") }
    public static var explanationSnapshots: String { t("・スナップショットやパージ可能な領域、システム領域の一部は走査で見えません。", "• Snapshots, purgeable space, and parts of the system area aren’t visible to the scan.") }
    public static var explanationAllocated: String { t("・割り当て済みサイズは、その項目だけが占める容量とは限らず、ゴミ箱へ移して空き容量が同じだけ増えるとも限りません。", "• An item’s allocated size may not be space used only by that item, and moving it to the Trash may not free the same amount.") }
    public static var explanationCapacity: String { t("・ボリューム容量は macOS が報告する値で、取得時刻の時点のものです。", "• Volume capacity is what macOS reports, as of the time shown.") }
    public static var parentFolderHelp: String { t("親フォルダへ（⌘↑）", "Go to enclosing folder (⌘↑)") }
    public static func filesCount(_ value: Int) -> String { t("ファイル \(count(value)) 件", value == 1 ? "1 file" : "\(count(value)) files") }
    public static func foldersCount(_ value: Int) -> String { t("フォルダ \(count(value)) 件", value == 1 ? "1 folder" : "\(count(value)) folders") }
    public static func missingCount(_ value: Int) -> String { t("未取得 \(count(value)) 件", "Missing: \(count(value))") }
    public static var missingHelp: String { t("アクセス拒否・読み取りエラー・クラウド上のみなど、情報を取得できなかった項目です。クリックすると一覧を表示します。", "Items whose information couldn’t be read, such as access denied, read errors, or cloud-only items. Click to see the list.") }
    public static func excludedCount(_ value: Int) -> String { t("除外 \(count(value)) 件", "Excluded: \(count(value))") }
    public static var excludedHelp: String { t("別ボリューム・別経路・デバイス領域など、走査範囲の規則により走査しなかった場所です。クリックすると一覧を表示します。", "Locations not scanned because of scope rules, such as other volumes, alternate paths, or device areas. Click to see the list.") }
    public static func started(_ time: String) -> String { t("開始 \(time)", "Started \(time)") }
    public static func elapsed(_ value: String) -> String { t("経過 \(value)", "Elapsed \(value)") }
    public static func took(_ value: String) -> String { t("所要 \(value)", "Took \(value)") }
    public static var stop: String { t("中止", "Stop") }
    public static var stopping: String { t("中止しています…", "Stopping…") }
    public static var forceStop: String { t("強制中止", "Force Stop") }
    public static var forceStopHelp: String { t("停止の確認を待たずに、ここまでの結果で中止します。応答しない場所（ネットワーク上のフォルダなど）で止まっている場合に使います。", "Stops the scan now and keeps the results so far. Use this if a location that isn’t responding, such as a network folder, is blocking the scan.") }
    public static var rescan: String { t("再スキャン", "Scan Again") }
    public static var rescanHelp: String { t("選んだ対象全体を走査し直し、結果を置き換えます", "Scans the whole location again and replaces the results") }

    // MARK: - アプリ: 一覧

    public static var columnName: String { t("名前", "Name") }
    public static var columnAllocatedSize: String { t("割り当て済みサイズ", "Allocated Size") }
    public static var columnShare: String { t("割合", "Share") }
    public static var columnStatus: String { t("状態", "Status") }
    public static var columnLocation: String { t("場所", "Location") }
    public static var columnDetails: String { t("詳細", "Details") }
    public static var movedToTrash: String { t("ゴミ箱へ移動済み", "Moved to Trash") }
    public static var provisionalNote: String { t("上位の一部だけを表示しています。すべての項目はスキャン完了後に表示できます。", "Only some of the largest items are shown. All items are available after the scan finishes.") }
    public static var emptyDenied: String { t("このフォルダは読み取れませんでした", "Folder Couldn’t Be Read") }
    public static var emptyError: String { t("このフォルダの読み取り中にエラーが起きました", "Error Reading Folder") }
    public static var emptyNotScanned: String { t("このフォルダは走査していません", "Folder Not Scanned") }
    public static var emptyScanning: String { t("スキャン中です", "Scanning…") }
    public static var emptyCancelled: String { t("走査を中止したため、このフォルダの中身は取得していません", "Folder Contents Not Read") }
    public static var emptyExcluded: String { t("このフォルダは除外したため走査していません", "Folder Excluded") }
    public static var emptyFolder: String { t("空のフォルダです", "Empty Folder") }
    public static var noFilesYet: String { t("まだファイルが見つかっていません", "No Files Found Yet") }
    public static var noFiles: String { t("ファイルがありません", "No Files") }

    // MARK: - アプリ: ツリーマップ

    public static var treemapPartial: String { t("部分的な結果です。読み取れなかった場所・未走査の場所は面積に含みません。", "Partial results. Locations that couldn’t be read or weren’t scanned aren’t included in the areas.") }
    public static var treemapEmptyTitle: String { t("表示できる容量がありません", "Nothing to Show") }
    public static var treemapEmptyDetail: String { t("このフォルダの直下には、サイズが 0 バイトより大きいと分かっている項目がありません。すべての項目は一覧で確認できます。", "No item directly in this folder is known to be larger than 0 bytes. All items are available in the list.") }
    public static func treemapOthersLink(count value: Int, size: String) -> String { t("その他 \(count(value)) 件（\(size)）を一覧で表示", value == 1 ? "Show 1 other item (\(size)) in the list" : "Show \(count(value)) other items (\(size)) in the list") }
    public static func treemapOthersTile(count value: Int) -> String { t("その他 \(count(value)) 件", value == 1 ? "1 other" : "\(count(value)) others") }
    public static var treemapAccessibility: String { t("容量のツリーマップ。一覧タブでも同じ項目をキーボードで操作できます。", "Treemap of space usage. The same items can be used with the keyboard in the List tab.") }

    // MARK: - アプリ: 詳細パネル

    public static var detailName: String { t("名前", "Name") }
    public static var detailLocation: String { t("場所", "Location") }
    public static var detailKind: String { t("種類", "Kind") }
    public static var detailSize: String { t("サイズ", "Size") }
    public static var detailAllocated: String { t("割り当て済み", "Allocated") }
    public static var detailLogical: String { t("論理", "Logical") }
    public static var detailUnknownItems: String { t("サイズ不明の項目", "Items with unknown size") }
    public static func itemsCount(_ value: Int) -> String { t("\(count(value)) 件", "\(count(value))") }
    public static var detailUnreadableLocations: String { t("読み取れなかった場所", "Locations not read") }
    public static func locationsCount(_ value: Int) -> String { t("\(count(value)) か所", "\(count(value))") }
    public static var detailDates: String { t("日時", "Dates") }
    public static var detailModified: String { t("更新", "Modified") }
    public static var detailCreated: String { t("作成", "Created") }
    public static var detailStatus: String { t("状態", "Status") }
    public static var detailExcludedOtherVolume: String { t("別の対象として選ぶとスキャンできます。読み取りに失敗したわけではありません。", "You can scan it by selecting it as a separate target. This isn’t a read failure.") }
    public static var detailExcludedByRule: String { t("走査範囲の規則により走査していません。読み取りに失敗したわけではありません。", "Not scanned because of scope rules. This isn’t a read failure.") }
    public static var showInFolderHelp: String { t("この項目を含むフォルダを一覧で開き、項目を選択します（⌘L）", "Opens the folder containing this item in the list and selects it (⌘L)") }
    public static var selectItem: String { t("項目を選択してください", "Select an Item") }
    public static var moving: String { t("移動しています…", "Moving…") }
    public static var moveToTrashEllipsis: String { t("ゴミ箱へ移動…", "Move to Trash…") }

    // MARK: - アプリ: 場所の一覧と権限

    public static var noMatchingLocations: String { t("該当する場所はありません", "No Locations") }
    public static var problemsTitle: String { t("情報を取得できなかった場所", "Locations with Missing Information") }
    public static var excludedTitle: String { t("除外した場所", "Excluded Locations") }
    public static var problemsExplanation: String { t("アクセス拒否・読み取りエラーの場所と、クラウド上にのみあり一覧を取得できなかったフォルダです。読み取れなかった部分の容量は集計に含まれず、読み取れなかったフォルダの中にある項目の数も分かりません。", "Locations with access denied or read errors, and cloud-only folders whose contents couldn’t be listed. Space in the parts that couldn’t be read isn’t included, and the number of items inside unreadable folders is unknown.") }
    public static var excludedExplanation: String { t("二重に数えないため、または走査範囲の規則により、意図的に走査しなかった場所です（別のボリューム、同じフォルダへの別経路、起動ディスクの別名経路、デバイス領域など）。読み取りに失敗したわけではありません。外付けディスクは、別の対象として選択するとスキャンできます。", "Locations intentionally not scanned to avoid counting them twice or because of scope rules (other volumes, alternate paths to the same folder, alias paths on the startup disk, device areas, and so on). These aren’t read failures. You can scan an external disk by selecting it as a separate target.") }
    public static var permissionGuidance: String { t("アクセスが拒否された場所は、このアプリに「フルディスクアクセス」を許可すると読み取れるようになる場合があります。ただし、システムが保護している場所は許可後も読み取れないことがあり、フォルダのアクセス権など別の原因によることもあります。", "Locations where access was denied may become readable if you give this app Full Disk Access. However, some locations protected by the system may remain unreadable, and the cause may be something else, such as folder permissions.") }
    public static var permissionSteps: String { t("許可する場合: 設定の一覧でこのアプリをオンにします（一覧にない場合は「+」で追加します）。その後アプリを再起動し、再スキャンしてください。", "To allow access, turn on this app in the Full Disk Access list in System Settings. If it isn’t listed, click the Add button (+). Then quit and reopen the app, and scan again.") }
    public static var openFullDiskAccess: String { t("フルディスクアクセスの設定を開く", "Open Full Disk Access Settings") }
    public static var openFullDiskAccessHelp: String { t("システム設定の「プライバシーとセキュリティ」→「フルディスクアクセス」を開きます。許可はご自身で行ってください。", "Opens Privacy & Security > Full Disk Access in System Settings. You make the change yourself.") }

    // MARK: - アプリ: お知らせ

    public static var cannotStartScan: String { t("スキャンを開始できません", "Can’t Start the Scan") }
    public static var networkNotSupported: String { t("ネットワーク上の場所はスキャンの対象外です。Mac に接続したディスク、またはその中のフォルダを選択してください。", "Network locations can’t be scanned. Select a disk connected to this Mac, or a folder on it.") }
    public static func targetNotFound(_ name: String) -> String { t("「\(name)」の場所を確認できませんでした。", "The location of “\(name)” couldn’t be found.") }
    public static var waitForTrash: String { t("ゴミ箱への移動が終わってから、もう一度お試しください。", "Try again after the move to the Trash finishes.") }
    public static var previousScanStopping: String { t("前のスキャンを停止しています。しばらくしてからもう一度お試しください。", "The previous scan is stopping. Try again in a moment.") }
    public static var cannotMoveToTrash: String { t("ゴミ箱へ移動できません", "Can’t Move to Trash") }
    public static var didNotMoveToTrash: String { t("ゴミ箱へ移動しませんでした", "Not Moved to Trash") }
    public static var resultsReplaced: String { t("確認している間に結果が新しいスキャンに置き換わりました。項目を選び直してください。", "The results were replaced by a new scan while you were confirming. Select the item again.") }
    public static var movedToTrashTitle: String { t("ゴミ箱へ移動しました", "Moved to Trash") }
    public static func movedButUnverified(_ name: String) -> String {
        t("ゴミ箱に入った項目が「\(name)」と同じであることを確認できませんでした（移動先を読み取れない、またはファイルシステムが識別情報を引き継がないため）。ゴミ箱で確認してください。",
          "Couldn’t confirm that the item in the Trash is “\(name)” (the Trash couldn’t be read, or the file system doesn’t keep the item’s identity). Check the Trash.")
    }
    public static var checkTrashTitle: String { t("ゴミ箱の中身を確認してください", "Check the Trash") }
    public static var moveFailedTitle: String { t("ゴミ箱へ移動できませんでした", "Couldn’t Move to Trash") }
}
