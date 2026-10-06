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
                    L10n.chooseTarget,
                    systemImage: "internaldrive",
                    description: Text(L10n.chooseTargetDetail)
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
                        Label(L10n.details, systemImage: "sidebar.right")
                    }
                    .help(L10n.detailsHelp)
                }
            }
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text(L10n.ok)))
        }
        .confirmationDialog(
            L10n.switchScanTitle,
            isPresented: $model.isSwitchConfirmationPresented
        ) {
            Button(L10n.switchScanConfirm) {
                Task { await model.startScan() }
            }
            Button(L10n.switchScanKeep, role: .cancel) {}
        } message: {
            Text(L10n.switchScanDetail)
        }
        .confirmationDialog(
            L10n.trashConfirmTitle,
            isPresented: $model.isTrashDialogPresented,
            presenting: model.pendingTrash
        ) { candidate in
            Button(L10n.trashConfirmButton, role: .destructive) {
                // ダイアログが閉じると pendingTrash は消えるため、表示していた値をそのまま渡す
                Task { await model.confirmTrash(candidate) }
            }
            Button(L10n.cancel, role: .cancel) {
                model.cancelTrash()
            }
        } message: { candidate in
            Text(trashMessage(candidate))
        }
    }

    private func trashMessage(_ candidate: TrashCandidate) -> String {
        L10n.trashConfirmMessage(
            name: DisplayText.visible(candidate.name),
            path: DisplayText.visible(candidate.path),
            size: ByteFormatting.string(candidate.allocatedSize)
        )
    }
}
