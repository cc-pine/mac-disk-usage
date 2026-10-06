import SwiftUI
import DiskUsageCore

struct ContentView: View {
    @Environment(ScanViewModel.self) private var model
    @State private var showsInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            StartView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if model.session == nil {
                ContentUnavailableView(
                    "スキャン対象を選択してください",
                    systemImage: "internaldrive",
                    description: Text("左の一覧からボリュームまたはフォルダを選択し、「スキャン」をクリックします。")
                )
            } else {
                ResultView()
                    .inspector(isPresented: $showsInspector) {
                        DetailView()
                            .inspectorColumnWidth(min: 260, ideal: 300)
                    }
            }
        }
        .toolbar {
            if model.session != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("詳細", systemImage: "sidebar.right")
                    }
                    .help("詳細パネルの表示を切り替えます")
                }
            }
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "実行中のスキャンを中止して、選んだ対象をスキャンしますか？",
            isPresented: $model.isSwitchConfirmationPresented
        ) {
            Button("中止してスキャン") {
                Task { await model.startScan() }
            }
            Button("スキャンを続ける", role: .cancel) {}
        } message: {
            Text("ここまでの結果は破棄され、新しい対象の結果に置き換わります。")
        }
        .confirmationDialog(
            "ゴミ箱へ移動しますか？",
            isPresented: $model.isTrashDialogPresented,
            presenting: model.pendingTrash
        ) { candidate in
            Button("ゴミ箱へ移動", role: .destructive) {
                // ダイアログが閉じると pendingTrash は消えるため、表示していた値をそのまま渡す
                Task { await model.confirmTrash(candidate) }
            }
            Button("キャンセル", role: .cancel) {
                model.cancelTrash()
            }
        } message: { candidate in
            Text(trashMessage(candidate))
        }
    }

    private func trashMessage(_ candidate: TrashCandidate) -> String {
        """
        名前: \(DisplayText.visible(candidate.name))
        場所: \(DisplayText.visible(candidate.path))
        割り当て済みサイズ: \(ByteFormatting.string(candidate.allocatedSize))

        ゴミ箱へ移動するだけで、項目は完全には削除されません。空き容量がこのサイズ分増えるとは限りません。
        """
    }
}
