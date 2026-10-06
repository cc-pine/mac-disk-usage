import SwiftUI
import DiskUsageCore

@main
struct DiskUsageApp: App {
    @State private var model = ScanViewModel()

    var body: some Scene {
        // 1つのモデルを複数のウィンドウで共有しないよう、単一ウィンドウにする
        Window(L10n.appTitle, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.loadVolumes() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button(L10n.menuScan) {
                    model.requestStartScan()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!model.canStartScan)

                Button(L10n.menuStopScan) {
                    model.cancelScan()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!model.isScanActive)
            }
            CommandMenu(L10n.menuGo) {
                Button(L10n.menuOpenSelection) {
                    model.openSelection()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
                .disabled(model.selectionID == nil)

                Button(L10n.menuParentFolder) {
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
                Button(L10n.menuShowInFolder) {
                    model.showSelectionInFolder()
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(model.selectedItem?.parentID == nil)

                Button(L10n.menuShowInFinder) {
                    model.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRevealSelection)
            }
        }
    }
}
