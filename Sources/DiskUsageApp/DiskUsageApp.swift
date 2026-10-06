import SwiftUI
import DiskUsageCore

@main
struct DiskUsageApp: App {
    @State private var model = ScanViewModel()

    var body: some Scene {
        // 1つのモデルを複数のウィンドウで共有しないよう、単一ウィンドウにする
        Window("ディスク使用量", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.loadVolumes() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("スキャン") {
                    model.requestStartScan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canStartScan)

                Button("スキャンを中止") {
                    model.cancelScan()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isScanActive)
            }
            CommandMenu("移動") {
                Button("選択項目を開く") {
                    model.openSelection()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(model.selectionID == nil)

                Button("親フォルダへ") {
                    model.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(!model.canGoUp)

                Divider()
                ForEach(Array(ResultTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) {
                        model.tab = tab
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }

                Divider()
                Button("フォルダ内で表示") {
                    model.showSelectionInFolder()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(model.selectedItem?.parentID == nil)

                Button("Finder で表示") {
                    model.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRevealSelection)
            }
        }
    }
}
