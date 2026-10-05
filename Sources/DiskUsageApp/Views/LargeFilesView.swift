import SwiftUI
import DiskUsageCore

/// スキャン対象全体の通常ファイルをサイズ順に表示する。表示中のフォルダには限定しない。
struct LargeFilesView: View {
    @Environment(ScanViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let page = model.largeFiles {
                if page.totalCount == 0 {
                    ContentUnavailableView(
                        model.isScanActive ? "まだファイルが見つかっていません" : "ファイルがありません",
                        systemImage: "doc"
                    )
                } else {
                    ItemTable(
                        items: page.items,
                        total: model.scanRoot?.displayAllocatedBytes ?? 0,
                        moved: model.movedItems,
                        selection: $model.selectionID,
                        showsPath: { item in
                            item.id == model.selectionID ? model.selectedPath : nil
                        }
                    ) { item in
                        model.selectionID = item.id
                    }
                    PageBar(page: page, pageSize: ScanViewModel.pageSize) { offset in
                        model.showLargeFilesPage(offset: offset)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
