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
        }
    }
}
