import SwiftUI

@main
struct LogViewerApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") {
                    appState.openFilePanel()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("打开文件夹…") {
                    appState.openFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
