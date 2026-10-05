# 実装開始時の判断

[REQUIREMENTS.md](REQUIREMENTS.md) 第12節で「実装開始前に決める項目」とした事項の、初版実装での仮決定を記録する。製品としての確定ではなく、変更する場合はこの文書と関連箇所を同時に更新する。

## 配布形態と App Sandbox

- 初版は**開発用のみ**とする。Swift Package の実行ターゲットとしてビルドし、`scripts/make-app.sh` で未署名（ad-hoc 署名）の `.app` に包む。
- **App Sandbox は無効**とする。起動ディスク全体の走査は Sandbox 下ではユーザー選択の範囲に限られ、MVP の主要シナリオ（ボリューム選択）と両立しないため。
- そのため `AccessController` は security-scoped URL を扱う拡張点だけを持ち、初版では開始・終了を何もしない実装にする。Mac App Store 配布を検討する時点で見直す。

## 最低対応 macOS

- **macOS 14 (Sonoma)** 以上とする。SwiftUI の `@Observable`、`inspector`、`NavigationSplitView` を使うため。

## UI 言語

- 初版は**日本語のみ**とする。文字列は SwiftUI の文字列リテラルに直接書き、多言語化は MVP 後に検討する。

## 保護対象パス（ゴミ箱移動を禁止する場所）

初版の移動対象は**通常ファイル1件**のみ。次のいずれかに当たる項目は移動しない。

- 判定はパス文字列の前方一致ではなく、パス成分単位で行う。APFS の既定に合わせ、大文字・小文字を区別せずに比較する（禁止側に倒れる）。
- 表の場所は、その場所自身と配下すべてを指す。
- `.` / `..` を含むパス、絶対パスでないパスは判定できないため移動しない。

| 区分 | 対象 |
|---|---|
| システム領域 | `/System`（`/System/Volumes/Data` 経由の別名経路を含む）、`/Library`、`/bin`、`/sbin`、`/usr`、`/private`、`/etc`、`/var`、`/tmp`、`/dev`、`/cores`、`/opt` |
| アプリケーション | `/Applications`（`.app` 内部はパッケージ規則でも禁止） |
| ユーザーのライブラリ | すべてのユーザーの `/Users/*/Library` と `/Users/*/.Trash`。加えて、現在のユーザーのホーム（パスワードデータベースの値とその実体パス）の `Library`、`.Trash` |
| 他のボリューム | `/Volumes/*/` 直下の `System`、`Library`、`private`、`Applications`、`usr`、`bin`、`sbin`、`cores`、`opt`、`Users/*/Library`、`Users/*/.Trash`、`.Trashes`、`.Spotlight-V100`、`.fseventsd`、`.DocumentRevisions-V100`、`.TemporaryItems`、`Backups.backupdb`、`.MobileBackups` |
| 範囲 | スキャンルート自身、スキャン範囲外の項目、現在の結果ではない（再スキャン前の）結果の項目 |
| 構造 | ディレクトリ、シンボリックリンク、特殊ファイル、ハードリンクが複数あるファイル、パッケージ内部（スキャンルートより上の祖先がパッケージである場合、パッケージか判定できない場合を含む） |

外付けボリューム（`/Volumes/<名前>/...`）上の通常ファイルは、上記に当たらなければ移動できる。

移動の直前には、ルートから親までの各フォルダと対象ファイルの `(device, inode)`、種類、論理サイズ、更新日時、ハードリンク数を `lstat` で再確認する。移動はファイル参照 URL で行い、移動後にゴミ箱内の項目の識別情報を確かめ、一致しなければ利用者に知らせる。ゴミ箱移動とスキャンは `ScanCoordinator` のゲートで排他にする。

## サイズの取得方法

- 論理サイズは `lstat` の `st_size`、割り当て済みサイズは `st_blocks × 512` とする。URL リソース値（`totalFileAllocatedSize`）より高速で、ファイル内容やクラウド項目のダウンロードを伴わない。
- `totalFileAllocatedSize` と違い、拡張属性やリソースフォークの割り当ては含まない。この差は「走査集計とボリューム使用量は一致しない」という既存の説明の範囲に含める。
- パッケージ判定（`isPackage`）だけは macOS の URL リソース値から取得する。対象はディレクトリのみ。

## 起動ディスクの走査範囲

- 起動ディスクは論理ルート `/` を対象にし、許可するデバイスを「`/` のデバイス」と「`/System/Volumes/Data` のデバイス」の組とする。firmlink 経由の `/Users` などは Data 側のデバイスなので走査対象に含まれる。
- `/System/Volumes`、`/Volumes`、`/dev` は配下走査から除外し、除外理由を `scopeRule` として記録する。
- 訪問済みディレクトリの `(device, inode)` を記録し、別経路での再訪は `duplicatePath` として除外する。
- この規則が実機の macOS で期待どおりか（`/Users` が含まれ、`/System/Volumes/Data` が二重に数えられないか）は、CI の macOS ランナーでの結合テストと、手元の `.app` での確認で検証する。

## 性能評価

- 合成した100万件のファイルツリーを模擬ファイルシステムで走査するベンチマーク（`swift test --filter Benchmark` で任意実行）で、所要時間とストアのノード数を記録する。
- 実ディスクでの評価環境とピークメモリ・UI 応答時間の合格基準は未定とし、計測値は達成済みとみなさない。
