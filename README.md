# ディスク使用量（macOS）

選んだボリュームやフォルダを走査し、容量を多く使っているフォルダ・ファイルを一覧と Treemap で探すための macOS アプリ。Finder での表示と、確認付きの「ゴミ箱へ移動」（通常ファイル1件のみ）を備える。

- 要件: [REQUIREMENTS.md](REQUIREMENTS.md)
- 設計: [ARCHITECTURE.md](ARCHITECTURE.md)
- 用語: [CONTEXT.md](CONTEXT.md)
- 実装開始時の判断（配布形態・Sandbox・保護パスなど）: [DECISIONS.md](DECISIONS.md)
- 実装タスクと確認状況: [TASKS.md](TASKS.md)

## 動かす

macOS 14 以降と Swift 6 のツールチェーン（Xcode 16 以降）が必要。

```sh
# 開発用の .app を作る（ad-hoc 署名。配布用の署名・公証はしない）
scripts/make-app.sh
open build/DiskUsage.app

# または実行ファイルとして直接起動する
swift run DiskUsageApp
```

起動ディスクのより多くの場所を読み取るには、システム設定の「プライバシーとセキュリティ」→「フルディスクアクセス」でアプリを許可する（許可しても読み取れない場所は残る）。許可しなくても読み取れる範囲は走査でき、読み取れなかった場所は結果画面下部の「未取得」から確認できる。

## テスト

```sh
swift test                                   # コア層の単体テスト（macOS / Linux）
MDU_INTEGRATION=1 swift test --filter MacIntegrationTests   # macOS 実機の結合テスト
MDU_BENCHMARK=1 swift test -c release --filter BenchmarkTests  # 合成した100万ファイルの走査ベンチマーク
```

- 結合テストは、ホームフォルダに作る専用の一時フォルダのファイルだけを実際にゴミ箱へ移す（テスト後にゴミ箱から取り除く）。
- CI（GitHub Actions）は macOS で単体テスト・結合テスト・ベンチマーク・`.app` 作成を、Linux（Swift 6.0 / 6.3）で単体テストを実行する。

## 構成

```text
Sources/
├── DiskUsageCore/          プラットフォームに依存しない中核（Linux でもテスト可能）
│   ├── Model/              ScanItem・SizeSummary・ScanScope・ScanState・VolumeCapacity
│   ├── Support/            10進単位の容量表記（ByteFormatting）、成分単位のパス操作（PathUtilities）
│   ├── FileSystem/         FileSystemProvider と、lstat・open(O_NOFOLLOW)・fdopendir・fstatat による実装
│   ├── Scan/               FileSystemScanner・ScanCoordinator・ScanSession・ScopeResolver
│   ├── Store/              ScanStore（ID 索引のノード、祖先への集計、ファイル索引）
│   ├── Treemap/            squarified Treemap のレイアウト計算
│   ├── Actions/            ゴミ箱移動の可否判定・再確認（ItemActionService・TrashPolicy）
│   └── Presentation/       不明値を 0 と表示しない文言の組み立て
└── DiskUsageApp/           SwiftUI アプリ（macOS 専用）
    ├── Model/              ScanViewModel・ScanTarget
    └── Views/              開始画面・結果画面・一覧・Treemap・詳細・場所の一覧
```

設計書との主な対応と、実装で決めた点:

- 列挙スレッドと保存スレッドを上限付きキューでつなぎ、保存用バッチは破棄しない。UI への進捗は 250 ms ごとに最新値だけを送り、終端イベントは全バッチの保存と大きなファイル一覧の索引作成の後に送る。
- 進捗用の版と件数は保存処理の本体とは別のロックで読めるため、保存中も UI の問い合わせを待たせない。
- サイズは `lstat` の `st_size`（論理）と `st_blocks × 512`（割り当て済み）から取る（[DECISIONS.md](DECISIONS.md)）。
- ゴミ箱移動とスキャンは `ScanCoordinator` のゲートで排他にし、移動直前に対象と親フォルダの識別情報を再確認する。

## 性能の計測値

合成した 1,000,000 ファイル・11,111 フォルダのツリー（ディスク I/O なし）での計測（2026-10-06、コミット d118b7f）。ピーク RSS は、下記の 200,000 ファイルの計測と同じテストプロセスで続けて実行したときの最大値。実ディスクでの評価環境と合格基準は未定（[DECISIONS.md](DECISIONS.md)）。

| 環境 | 走査 | 走査中の問い合わせの最大待ち | ピーク RSS | ノード1件の大きさ |
|---|---|---|---|---|
| GitHub Actions macos-15（release） | 約 2.8 秒 | 約 0.03 秒 | 約 410 MB | 112 バイト |
| WSL2 Ubuntu 24.04（release） | 約 1.5 秒 | 約 0.03 秒 | 約 250 MB | 112 バイト |

1つのフォルダに 200,000 ファイルがある場合、走査中に直下一覧を並べ替えている間も、別スレッドの項目取得の待ちは最大で約 0.004 秒（macos-15）・約 0.01 秒（WSL2）だった。

## 既知の制限

- アプリの画面を起動しての操作確認は、まだ行っていない（[TASKS.md](TASKS.md)）。
- 応答しないネットワークマウントなどで OS の呼び出しが戻らない場合、キャンセルの確定を待ち続け、アプリを再起動するまで次のスキャンを始められない（[DECISIONS.md](DECISIONS.md) の「キャンセルと停止の確定」）。
- 実ディスクでの性能の評価環境と合格基準は未定。上の計測値は合成データでのもの。
