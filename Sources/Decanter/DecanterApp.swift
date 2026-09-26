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

        Window("About Decanter", id: "about") {
            AboutView().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called for Finder's "Open With Decanter", or when an .exe is dropped on the Dock icon.
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Decanter") { openWindow(id: "about") }
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
            let game = model.game(model.selection)
            Button("Play") { game.map { model.play($0) } }
                .keyboardShortcut("r")
                .disabled(model.needsSetup || game == nil)
            // Also cancels a game that's still starting.
            Button("Stop") { game.map { model.stop($0) } }
                .keyboardShortcut(".")
                .disabled(game.map { model.running[$0.id] == nil && !model.starting.contains($0.id) } ?? true)
            Divider()
            Button("Show in Finder") { game.map { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) } }
                .disabled(game == nil)
            Button("Rename…") { model.renaming = game }
                .disabled(game == nil)
            Button("Remove from Library…") { game.map { model.requestRemoval(of: $0) } }
                .disabled(game == nil)
            Divider()
            Button("Wine Configuration…") { model.openWineTool("winecfg", engine: model.selectedEngine) }
            Button("Show C: Drive in Finder") { model.showDriveC(model.selectedEngine) }
            Divider()
            Button("Force Quit All Windows Programs") { model.stopAll() }
        }
        CommandGroup(replacing: .help) {
            Button("Decanter Help") { NSWorkspace.shared.open(HelpLinks.readme) }
                .keyboardShortcut("?")
            Button("Report a Problem…") { NSWorkspace.shared.open(HelpLinks.newIssue) }
        }
    }
}

/// Where the Help menu goes: the README, and a new GitHub issue that already says which
/// Decanter and macOS it's about.
enum HelpLinks {
    static let readme = URL(string: "https://github.com/\(Updates.repo)#readme")!

    static var newIssue: URL {
        let body = """
            Decanter \(Updates.currentVersion) (\(Updates.build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

            **What happened?**


            **Which game, and where is it from?**


            **The game's log** (open Log under the game and press Copy, then paste it here):

            ```

            ```
            """
        var components = URLComponents(string: "https://github.com/\(Updates.repo)/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}
