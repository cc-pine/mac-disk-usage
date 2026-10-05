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
                    "スキャン対象を選んでください",
                    systemImage: "internaldrive",
                    description: Text("左の一覧からボリュームまたはフォルダを選び、「スキャン」を押します。")
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
                    .help("詳細パネルの表示を切り替える")
                }
            }
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("OK")))
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
        名前: \(candidate.name)
        場所: \(candidate.path)
        取得済みサイズ: \(ByteFormatting.string(candidate.allocatedSize))

        ゴミ箱へ移すだけで、完全には削除しません。空き容量がこのサイズだけ増えるとは限りません。
        """
    }
}
