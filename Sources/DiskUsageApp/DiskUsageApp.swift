import SwiftUI
import DiskUsageCore

@main
struct DiskUsageApp: App {
    @State private var model = ScanViewModel()

    var body: some Scene {
        WindowGroup("ディスク使用量") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { model.loadVolumes() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("スキャン") {
                    Task { await model.startScan() }
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
                Button("Finder で表示") {
                    model.revealSelectionInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canRevealSelection)
            }
        }
    }
}
