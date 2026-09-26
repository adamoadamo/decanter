import SwiftUI

@main
struct DecanterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Decanter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 900, height: 600)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder "Open With Decanter" or dropping an .exe on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            let model = AppModel.shared
            model.add(urls, playAfterAdding: !model.needsSetup)
        }
    }

    /// ⌘Q quits any running games along with Decanter.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.quitAllGamesForExit() }
        return .terminateNow
    }

    /// Closing the window quits Decanter only when nothing is playing, so closing it
    /// doesn't take a game down with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.running.isEmpty && AppModel.shared.starting.isEmpty }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { model.checkForUpdates(userInitiated: true) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Game…") { model.showAddPanel() }
                .keyboardShortcut("o")
            Button("Run Installer…") { model.showInstallerPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.needsSetup)
        }
        CommandMenu("Game") {
            Button("Play") { model.game(model.selection).map(model.play) }
                .keyboardShortcut("r")
                .disabled(model.needsSetup || model.selection == nil)
            Button("Stop") { model.game(model.selection).map(model.stop) }
                .keyboardShortcut(".")
                .disabled(model.selection.flatMap { model.running[$0] } == nil)
            Divider()
            Button("Wine Configuration…") { model.openWineTool("winecfg", engine: model.selectedEngine) }
            Button("Show C: Drive in Finder") { model.showDriveC(model.selectedEngine) }
            Divider()
            Button("Force Quit All Windows Programs") { model.stopAll() }
        }
    }
}
