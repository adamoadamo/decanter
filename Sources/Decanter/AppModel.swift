import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Game: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var exePath: String
    var engine = Engine.default
    var graphics = Graphics.default
    /// When this is on, Decanter picks the engine and graphics (see Setup.candidates) and tries
    /// the next setup if the game closes or crashes as it starts. Choosing either by hand turns it off.
    var automatic = true
    /// How far down the Setup.candidates list an automatic game has had to go.
    var setupStep = 0
    var display = Display.gameSetting
    /// Launch options players typed in by hand before 1.2.4. They're no longer shown, but they're
    /// still passed to the game so one that was set up with them keeps working.
    var arguments = ""
    var added = Date()
    var lastPlayed: Date?

    init(name: String, exePath: String, engine: Engine = .default) {
        self.name = name
        self.exePath = exePath
        self.engine = engine
    }

    // Library files written by older versions have fewer fields, so this copes with any that are missing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Games installed with Run Installer live in the support folder, which moved when the app was renamed.
        exePath = AppPaths.migrated(try c.decode(String.self, forKey: .exePath))
        if c.contains(.engine) {
            engine = (try? c.decode(Engine.self, forKey: .engine)) ?? Engine.owning(exePath) ?? .default
        } else {
            // This was saved by 1.0, which only had Wine Staging. Leaving the game there keeps
            // its saves and settings, because they live in that engine's Windows environment.
            engine = .wine
        }
        graphics = (try? c.decodeIfPresent(Graphics.self, forKey: .graphics)) ?? .default
        // Before 1.2, a game was only on Wine Staging because 1.0 had nothing else or because
        // the player chose it. Either way, leave those games where they are.
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic)
            ?? (engine == .crossover || Engine.owning(exePath) != nil)
        setupStep = try c.decodeIfPresent(Int.self, forKey: .setupStep) ?? 0
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        // Before 1.2.4, "Run inside a window" used a Wine virtual desktop. Those games now open Windowed.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        display = try c.decodeIfPresent(Display.self, forKey: .display)
            ?? (try legacy.decodeIfPresent(Bool.self, forKey: .virtualDesktop) == true ? .windowed : .gameSetting)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }

    var url: URL { URL(fileURLWithPath: exePath) }

    private enum LegacyKeys: String, CodingKey { case virtualDesktop }

    /// Settings older versions saved that this one has replaced, so dropping them loses nothing.
    static let retiredKeys: Set = ["virtualDesktop", "desktopSize"]
}

enum SetupState: Equatable {
    case idle
    case working(String, Double?)
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    static let windowsTypes: [UTType] = [
        UTType("com.microsoft.windows-executable") ?? .exe,
        UTType("com.microsoft.msi-installer") ?? .data,
    ]

    var games: [Game] = [] { didSet { saveLibrary() } }
    var selection: Game.ID?

    /// The engines that are installed. If an engine has no entry, it isn't installed.
    var engines: [Engine: WineBinary] = [:]
    var versions: [Engine: String] = [:]
    /// How each engine's download and setup is going. An engine with no entry is idle.
    var installs: [Engine: SetupState] = [:]
    var rosettaMissing = false
    /// Keeps the first-run screen up from the moment its Download is pressed until the engine
    /// is ready, or while it shows a failure. Reinstalling from Settings doesn't set it.
    var firstRunSetup = false
    var customWinePath: String {
        didSet { UserDefaults.standard.set(customWinePath, forKey: "customWinePath") }
    }

    var starting: Set<UUID> = []
    var running: [UUID: Process] = [:]
    var logs: [UUID: String] = [:]
    var notices: [UUID: String] = [:]
    var installerRunning = false
    var pendingInstaller: URL?
    var alert: String?
    /// A release newer than this one, kept until the player dismisses it.
    var update: Updates.Release?
    var updateStatus = Updates.Status.unknown
    /// The game the player asked to remove, until they confirm or cancel.
    var pendingRemoval: Game?
    /// The game being renamed in the Rename sheet.
    var renaming: Game?

    @ObservationIgnored private var runningWine: [UUID: WineBinary] = [:]
    @ObservationIgnored private var launchedAt: [UUID: Date] = [:]
    /// A token for each start, so one that was cancelled or replaced by a newer Play never launches.
    @ObservationIgnored private var startTokens: [UUID: UUID] = [:]
    /// How many setups Decanter has tried on its own for each game since Play was last pressed.
    @ObservationIgnored private var setupRetries: [UUID: Int] = [:]
    /// The setup each game was on when Play was pressed, so it can go back there if none work.
    @ObservationIgnored private var startStep: [UUID: Int] = [:]
    /// Games that crashed as they started and were stopped, so they relaunch with the next setup.
    @ObservationIgnored private var retryOnExit: Set<UUID> = []
    /// The end of the current run's log, which is searched for crash messages. It starts empty
    /// each run so a crash from an earlier attempt in the same log isn't mistaken for a new one.
    @ObservationIgnored private var crashScanTail: [UUID: String] = [:]
    @ObservationIgnored private var stopping: Set<UUID> = []
    /// Windows environments being reset. Anything that needs one waits for the reset to finish.
    @ObservationIgnored private var resetTasks: [Engine: Task<Void, Never>] = [:]
    /// Turned off when part of the library couldn't be read and no copy of it could be kept,
    /// so a partial list never gets saved over the original.
    @ObservationIgnored private var canSaveLibrary = true
    /// Who asked for the running update check, and so how to answer. It's nil for the quiet
    /// check at launch, an alert for the menu, and an answer in place for the About window.
    @ObservationIgnored private var updateAnswer: UpdateAnswer?
    private enum UpdateAnswer { case alert, about }
    @ObservationIgnored private var iconCache: [UUID: NSImage] = [:]
    @ObservationIgnored private var makers: [String: Maker?] = [:]
    @ObservationIgnored private var missingIcons: Set<UUID> = []
    @ObservationIgnored private var prepareTasks: [Engine: Task<WineBinary, Error>] = [:]
    @ObservationIgnored private lazy var quitHotKey = QuitHotKey { [weak self] in
        MainActor.assumeIsolated { self?.quitFrontmostGame() }
    }

    private init() {
        customWinePath = AppPaths.migrated(UserDefaults.standard.string(forKey: "customWinePath") ?? "")
        loadLibrary()
        selection = games.first?.id
        refreshEngines()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateQuitHotKey() }
        }
        checkForUpdates()
    }

    // MARK: Updates

    /// Every launch checks quietly and says nothing about errors or a version the player skipped.
    /// Check for Updates… always gets an answer, as an alert from the menu or in place in the
    /// About window, even if a check was already running when it was asked.
    func checkForUpdates(userInitiated: Bool = false, answerInAbout: Bool = false) {
        if case .installing = updateStatus { return }
        if userInitiated { updateAnswer = answerInAbout ? .about : .alert }
        guard updateStatus != .checking else { return }  // The check that's already running will answer.
        updateStatus = .checking
        Task {
            var latest: Updates.Release?
            var failed = false
            do { latest = try await Updates.latest() } catch { failed = true }
            // An install may have started while this was checking. If so, leave it alone.
            guard updateStatus == .checking else { return }
            let answer = updateAnswer
            updateAnswer = nil
            if let latest, Updates.isNewer(latest.version, than: Updates.currentVersion) {
                updateStatus = .available(latest)
                let skipped = UserDefaults.standard.string(forKey: "skippedVersion") == latest.version
                if answer == .alert || (answer == nil && !skipped) { update = latest }
            } else if failed {
                updateStatus = .failed
                if answer == .alert { alert = "Couldn’t check for updates. Check your internet connection and try again." }
            } else {
                updateStatus = .upToDate
                if answer == .alert { alert = "Decanter \(Updates.currentVersion) is the latest version." }
            }
        }
    }

    /// Puts the release in place of this copy of Decanter and restarts, which quits any
    /// games that are running. If that can't be done, the release's page opens instead.
    func installUpdate(_ release: Updates.Release) {
        if case .installing = updateStatus { return }
        update = nil
        updateStatus = .installing(release)
        Task {
            do {
                let installed = try await Updates.install(release)
                Updates.openWhenQuit(installed)
                NSApp.terminate(nil)
            } catch {
                updateStatus = .available(release)
                alert = "Couldn’t update Decanter. \(error.localizedDescription) The download page is opening so you can update it yourself."
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    func skip(_ release: Updates.Release) {
        UserDefaults.standard.set(release.version, forKey: "skippedVersion")
        update = nil
    }

    // MARK: Library

    var sortedGames: [Game] {
        games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func game(_ id: UUID?) -> Game? { games.first { $0.id == id } }

    func binding(for id: UUID) -> Binding<Game>? {
        guard let game = game(id) else { return nil }
        return Binding(
            get: { self.game(id) ?? game },
            set: { new in
                if let i = self.games.firstIndex(where: { $0.id == id }) { self.games[i] = new }
            })
    }

    /// Handles files from drag-and-drop, the Add panel, or Finder's "Open With".
    func add(_ urls: [URL], playAfterAdding: Bool = false) {
        let windows = urls.filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        guard !windows.isEmpty else {
            alert = "Decanter opens Windows programs: .exe or .msi files."
            return
        }
        for url in windows {
            if Self.looksLikeInstaller(url) {
                pendingInstaller = url
            } else {
                let game = addToLibrary(url)
                if playAfterAdding { play(game) }
            }
        }
    }

    @discardableResult
    func addToLibrary(_ url: URL, engine: Engine? = nil) -> Game {
        if let existing = games.first(where: { $0.exePath == url.path }) {
            selection = existing.id
            return existing
        }
        let game = Game(name: Self.defaultName(for: url), exePath: url.path,
                        engine: engine ?? Engine.owning(url.path) ?? .default)
        if let ico = PEIcon.icoData(fromExecutableAt: url) {
            try? FileManager.default.createDirectory(at: AppPaths.icons, withIntermediateDirectories: true)
            try? ico.write(to: AppPaths.icon(for: game.id))
        }
        games.append(game)
        applySetup(to: game.id)
        selection = game.id
        return self.game(game.id) ?? game
    }

    func remove(_ game: Game) {
        stop(game)
        games.removeAll { $0.id == game.id }
        try? FileManager.default.removeItem(at: AppPaths.icon(for: game.id))
        iconCache[game.id] = nil
        logs[game.id] = nil
        notices[game.id] = nil
        if selection == game.id { selection = sortedGames.first?.id }
    }

    /// Asks the player to confirm first. ContentView shows the question and does the removal.
    func requestRemoval(of game: Game) { pendingRemoval = game }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].name = name
    }

    /// Points a game whose .exe has moved (or been replaced by a new build somewhere else) at
    /// the new file, keeping its settings. An automatic game starts again from its best setup.
    func locate(_ game: Game) {
        let fm = FileManager.default
        var folder = game.url.deletingLastPathComponent()
        while !fm.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let panel = NSOpenPanel()
        panel.message = "Where is “\(game.name)” now? Choose its .exe."
        panel.prompt = "Choose"
        panel.allowedContentTypes = Self.windowsTypes
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url,
              let i = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[i].exePath = url.path
        games[i].setupStep = 0
        applySetup(to: game.id)
        if let ico = PEIcon.icoData(fromExecutableAt: url) {
            try? FileManager.default.createDirectory(at: AppPaths.icons, withIntermediateDirectories: true)
            try? ico.write(to: AppPaths.icon(for: game.id))
        }
        iconCache[game.id] = nil
        missingIcons.remove(game.id)
        notices[game.id] = nil
    }

    func icon(for game: Game) -> NSImage? {
        if let image = iconCache[game.id] { return image }
        guard !missingIcons.contains(game.id),
              let image = NSImage(contentsOf: AppPaths.icon(for: game.id)) else {
            missingIcons.insert(game.id)
            return nil
        }
        iconCache[game.id] = image
        return image
    }

    func showAddPanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Windows game (.exe)"
        panel.allowedContentTypes = Self.windowsTypes
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// The library lives outside the app, so it carries over when a new build of Decanter
    /// replaces an old one. Loading rewrites it, so anything this build can't keep (a damaged
    /// file, or games and settings saved by a newer build) is copied aside first.
    private func loadLibrary() {
        guard let data = try? Data(contentsOf: AppPaths.library) else { return }
        // Read each game on its own, so one unreadable entry doesn't lose all the others.
        struct Entry: Decodable {
            let game: Game?
            init(from decoder: Decoder) throws { game = try? Game(from: decoder) }
        }
        let entries = try? JSONDecoder().decode([Entry].self, from: data)
        let saved = entries?.compactMap(\.game) ?? []
        if saved.count != entries?.count || Self.rewriteLoses(data, saved) {
            let stamp = Date().formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
            let copy = AppPaths.support.appendingPathComponent("library-\(stamp).json")
            if (try? FileManager.default.copyItem(at: AppPaths.library, to: copy)) != nil {
                alert = "Part of your game library couldn’t be read, possibly because a newer Decanter saved it. The original is kept as \(copy.lastPathComponent) in Decanter’s Application Support folder."
            } else {
                // There's no copy, so don't save over the original either.
                canSaveLibrary = false
                alert = "Part of your game library couldn’t be read, and Decanter couldn’t keep a copy of it. Changes to your library won’t be saved until Decanter is restarted."
            }
        }
        games = saved
    }

    /// Whether saving `games` over `data` would lose fields or engines this build doesn't know about.
    private static func rewriteLoses(_ data: Data, _ games: [Game]) -> Bool {
        guard let old = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let new = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(games))) as? [[String: Any]],
              old.count == new.count else { return true }
        return zip(old, new).contains { old, new in
            old.keys.contains { new[$0] == nil && !Game.retiredKeys.contains($0) }
                || old["engine"].map { $0 as? String != new["engine"] as? String } == true
        }
    }

    private func saveLibrary() {
        guard canSaveLibrary else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(games).write(to: AppPaths.library, options: .atomic)
    }

    /// The name the game gives itself, if it has one (see shippedName). Otherwise a generic
    /// name like "Game.exe" in "Cool Game/bin/x64" becomes "Cool Game".
    static func defaultName(for url: URL) -> String {
        if let shipped = shippedName(for: url) { return shipped }
        let generic: Set = ["game", "start", "launcher", "play", "main", "nw", "run", "app", "client", "win", "windows"]
        let plumbing: Set = ["bin", "x64", "x86", "win64", "win32", "binaries", "game", "release"]
        let base = url.deletingPathExtension().lastPathComponent
        guard generic.contains(base.lowercased()) else {
            return base.replacingOccurrences(of: "_", with: " ")
        }
        var folder = url.deletingLastPathComponent()
        while plumbing.contains(folder.lastPathComponent.lowercased()), folder.pathComponents.count > 2 {
            folder = folder.deletingLastPathComponent()
        }
        return folder.pathComponents.count > 1 ? folder.lastPathComponent : base
    }

    /// The name some engines store next to the game. Unity puts it in `_Data/app.info` (company,
    /// then product), and NW.js games such as RPG Maker MV put it in `package.json`.
    static func shippedName(for exe: URL) -> String? {
        let folder = exe.deletingLastPathComponent()
        var names: [String?] = []
        let info = folder.appendingPathComponent(exe.deletingPathExtension().lastPathComponent + "_Data/app.info")
        if let text = try? String(contentsOf: info, encoding: .utf8) {
            names.append(text.components(separatedBy: .newlines).dropFirst().first)
        }
        for json in ["package.json", "www/package.json"].map(folder.appendingPathComponent) {
            guard let data = try? Data(contentsOf: json),
                  let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            names.append((package["window"] as? [String: Any])?["title"] as? String)
            names.append(package["name"] as? String)
        }
        let placeholders: Set = ["", "game", "nw", "nwjs", "unity", "rmmv", "rmmz", "rpg maker", "rpgmaker"]
        return names.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !placeholders.contains($0.lowercased()) }
    }

    static func looksLikeInstaller(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("unins") { return false }
        return url.pathExtension.lowercased() == "msi" || name.contains("setup") || name.contains("install")
    }

    // MARK: Engines

    func installState(_ engine: Engine) -> SetupState { installs[engine] ?? .idle }

    /// The first-run screen shows only when no engine is installed at all. Someone who already
    /// has Wine Staging goes straight to their library, and CrossOver downloads on first Play.
    var needsSetup: Bool { engines.isEmpty || firstRunSetup }

    /// The engine the menu commands act on: the selected game's, or the default if there's none.
    var selectedEngine: Engine { game(selection)?.engine ?? .default }

    func isInUse(_ engine: Engine) -> Bool {
        running.keys.contains { runningWine[$0]?.engine == engine }
    }

    func refreshEngines() {
        rosettaMissing = !WineLocator.rosettaAvailable
        for engine in Engine.allCases {
            let found = WineLocator.find(engine, customPath: customWinePath)
            if engines[engine] != found { versions[engine] = nil }
            engines[engine] = found
            if let found, versions[engine] == nil {
                Task { versions[engine] = await Wine.version(found) }
            }
        }
    }

    /// Downloads (or re-downloads) an engine and sets up its Windows environment.
    func download(_ engine: Engine) {
        guard !installState(engine).isWorking, prepareTasks[engine] == nil, !isInUse(engine) else { return }
        Task { try? await prepare(engine, reinstall: true) }
    }

    /// What the first-run screen's Download and Try Again buttons do.
    func setUpFirstRun() {
        firstRunSetup = true
        Task {
            if (try? await prepare(.default)) != nil { firstRunSetup = false }
        }
    }

    /// Gets an engine ready to run games by downloading it if needed, then creating its Windows
    /// environment. Progress and failures go to `installs[engine]`, which stays "working" until
    /// both steps finish so the window doesn't flicker between them. If several callers ask at
    /// once, they all share one run.
    @discardableResult
    private func prepare(_ engine: Engine, reinstall: Bool = false) async throws -> WineBinary {
        // Let any reset finish first, so nothing starts in a folder that's being deleted.
        if let reset = resetTasks[engine] { await reset.value }
        // If a run is already under way, join it. That way nobody launches a game from an
        // engine that's being replaced or from a prefix that's only half made.
        if let task = prepareTasks[engine] { return try await task.value }
        if !reinstall, let wine = engines[engine], Wine.prefixReady(engine) { return wine }
        let task = Task { () throws -> WineBinary in
            do {
                if reinstall || engines[engine] == nil {
                    installs[engine] = .working("Getting \(engine.title)…", nil)
                    _ = try await WineInstaller().install(engine) { step in
                        Task { @MainActor in self.show(step, for: engine) }
                    }
                    if engine == .wine { customWinePath = "" }
                    versions[engine] = nil
                    refreshEngines()
                }
                guard let wine = engines[engine] else { throw WineError.notFound }
                if !Wine.prefixReady(engine) {
                    installs[engine] = .working("Setting up \(engine.title)’s Windows environment. This only happens once and takes about a minute…", nil)
                    try await Wine.preparePrefix(wine)
                }
                installs[engine] = nil
                return wine
            } catch {
                installs[engine] = .failed(error.localizedDescription)
                throw error
            }
        }
        prepareTasks[engine] = task
        defer { prepareTasks[engine] = nil }
        return try await task.value
    }

    private func show(_ step: WineInstaller.Step, for engine: Engine) {
        guard installState(engine).isWorking else { return }
        switch step {
        case .locating:
            installs[engine] = .working("Getting \(engine.title)…", nil)
        case let .downloading(part, parts, received, total):
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let of = parts > 1 ? " (part \(part) of \(parts))" : ""
            let fraction = total > 0 ? Double(received) / Double(total) : nil
            installs[engine] = .working("Downloading \(engine.title)\(of), \(size)…", fraction)
        case .unpacking:
            installs[engine] = .working("Unpacking \(engine.title)…", nil)
        }
    }

    func chooseWine() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Wine app (e.g. “Wine Stable.app”) or its wine program"
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard WineLocator.binary(at: url) != nil else {
            alert = "That doesn’t look like a Wine installation."
            return
        }
        customWinePath = url.path
        refreshEngines()
    }

    func useAutomaticWine() {
        customWinePath = ""
        refreshEngines()
    }

    func installRosetta() {
        let script = AppPaths.support.appendingPathComponent("Install Rosetta.command")
        let text = """
            #!/bin/sh
            echo "Installing Rosetta 2, which Decanter needs to run Wine…"
            echo
            /usr/sbin/softwareupdate --install-rosetta
            echo
            echo "Done. You can close this window and go back to Decanter."
            """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            alert = "Couldn’t start the Rosetta installer: \(error.localizedDescription)"
        }
    }

    // MARK: Playing

    /// `retry` means Decanter is trying the next setup on its own, rather than the player pressing Play.
    func play(_ game: Game, retry: Bool = false) {
        guard running[game.id] == nil, !starting.contains(game.id) else { return }
        if !retry {
            setupRetries[game.id] = 0
            startStep[game.id] = game.setupStep
        }
        applySetup(to: game.id)
        guard let game = self.game(game.id) else { return }
        // Rosetta may have been installed from Settings since the last check.
        if rosettaMissing { rosettaMissing = !WineLocator.rosettaAvailable }
        guard !rosettaMissing else {
            notices[game.id] = "Wine needs Rosetta 2. Install it from the setup screen or Settings, then try again."
            return
        }
        // The game's page already says the file is missing and offers a Locate… button.
        guard FileManager.default.fileExists(atPath: game.exePath) else {
            NSSound.beep()
            return
        }
        // Some games only use WebView2 for an optional web page, so warn rather than refuse to start.
        notices[game.id] = Setup.usesWebView2(game.url)
            ? "This game uses Microsoft Edge WebView2, which doesn’t work in Wine yet. If it asks to install WebView2, it probably can’t run."
            : nil
        if retry {
            // Keep the log of the attempt that failed, because it explains why Decanter switched.
            appendLog(game.id, "\n--- Trying \(Setup(engine: game.engine, graphics: game.graphics).title) ---\n",
                      scanForCrashes: false)
        } else {
            logs[game.id] = ""
        }
        crashScanTail[game.id] = ""
        let token = UUID()
        startTokens[game.id] = token
        starting.insert(game.id)
        Task {
            defer { finishStart(game.id, token) }
            do {
                let wine = try await prepare(game.engine)
                await installBundledRuntimes(for: game, with: wine)
                if game.graphics == .dxvk { await Wine.installDXVK(wine) }
                // Stop here if the game was cancelled, removed, force-quit or reset while it was getting ready.
                guard startTokens[game.id] == token, let current = self.game(game.id) else { return }
                // Launch with the game's current settings, since they may have changed in the meantime.
                running[game.id] = try launch(current, with: wine)
                runningWine[game.id] = wine
                launchedAt[game.id] = Date()
                updateQuitHotKey()
                if let i = games.firstIndex(where: { $0.id == game.id }) { games[i].lastPlayed = Date() }
            } catch {
                guard startTokens[game.id] == token else { return }
                notices[game.id] = "Couldn’t start the game: \(error.localizedDescription)"
            }
        }
    }

    /// Ends a start, unless it was cancelled and the game has been started again since.
    private func finishStart(_ id: UUID, _ token: UUID) {
        guard startTokens[id] == token else { return }
        startTokens[id] = nil
        starting.remove(id)
    }

    /// Runtime installers that games often ship next to their .exe, and the flags that make them silent.
    private static let runtimeInstallers: [(name: String, matches: (String) -> Bool, args: [String])] = [
        ("OpenAL", { $0 == "oalinst.exe" }, ["/s"]),
        ("Visual C++ runtime", { $0.hasPrefix("vcredist") || $0.hasPrefix("vc_redist") }, ["/q", "/norestart"]),
    ]

    /// Quietly installs any runtimes the game bundles (like oalinst.exe for OpenAL) the first time
    /// they turn up. The record of what's done lives inside the prefix, so a reset starts fresh.
    private func installBundledRuntimes(for game: Game, with wine: WineBinary) async {
        let record = wine.prefix.appendingPathComponent("decanter-runtimes.txt")
        let legacyRecord = wine.prefix.appendingPathComponent("yeobgamer-runtimes.txt")
        try? FileManager.default.moveItem(at: legacyRecord, to: record)  // The file's name from before Decanter was renamed.
        var done = Set(((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        let found = Self.runtimeInstallers(near: game.url).filter { !done.contains($0.key) }
        let notice = notices[game.id]

        for item in found {
            notices[game.id] = "Installing \(item.name) (included with the game)…"
            // A silent installer that's still going after three minutes is stuck. Don't let
            // it hold up the game forever.
            let status = try? await Wine.runAndWait(wine, [item.url.path] + item.args,
                                                    cwd: item.url.deletingLastPathComponent(), timeout: 180)
            let result = status.map { "exit \($0)" } ?? "timed out"
            appendLog(game.id, "Installed \(item.name) from \(item.url.lastPathComponent) (\(result))\n")
            done.insert(item.key)
        }
        if !found.isEmpty {
            try? done.sorted().joined(separator: "\n").write(to: record, atomically: true, encoding: .utf8)
            notices[game.id] = notice
        }
    }

    /// Looks up to three folders deep beside the game's .exe for known runtime installers.
    private static func runtimeInstallers(near exe: URL) -> [(name: String, url: URL, args: [String], key: String)] {
        // A game .exe sitting loose in one of these folders doesn't own the installers around it.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shared = [home] + ["Desktop", "Downloads", "Documents"].map { home.appendingPathComponent($0) }
        guard !shared.map(\.path).contains(exe.deletingLastPathComponent().path),
              let walker = FileManager.default.enumerator(
            at: exe.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(name: String, url: URL, args: [String], key: String)] = []
        var visited = 0
        while let url = walker.nextObject() as? URL, visited < 5000 {
            visited += 1
            if walker.level > 3 { walker.skipDescendants() }
            let file = url.lastPathComponent.lowercased()
            guard file.hasSuffix(".exe"),
                  let match = runtimeInstallers.first(where: { $0.matches(file) }) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            found.append((match.name, url, match.args, "\(file):\(size)"))
        }
        return found
    }

    private func launch(_ game: Game, with wine: WineBinary) throws -> Process {
        let exe = game.url
        var args: [String] = []
        if exe.pathExtension.lowercased() == "msi" { args += ["msiexec", "/i"] }
        args.append(exe.path)
        let maker = maker(of: game)
        args += maker?.launchArguments ?? []
        args += maker?.arguments(for: game.display) ?? []
        args += splitArguments(game.arguments)

        // Run from the game's folder, because most games load their files relative to it.
        let process = Wine.process(wine, args, cwd: exe.deletingLastPathComponent(), graphics: game.graphics)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let id = game.id
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self.appendLog(id, text) }
        }
        let started = Date()
        process.terminationHandler = { p in
            let status = p.terminationStatus
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.launchedProgramExited(id, p, status: status, after: seconds) }
        }
        let version = versions[wine.engine].map { " (\($0))" } ?? ""
        let madeWith = maker.map { ", made with \($0.title)" } ?? ""
        appendLog(id, "[\(wine.engine.title)\(version)\(madeWith)] $ wine \(args.joined(separator: " "))\n")
        try process.run()
        return process
    }

    private func appendLog(_ id: UUID, _ text: String, scanForCrashes: Bool = true) {
        var log = (logs[id] ?? "") + text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
        logs[id] = log
        guard scanForCrashes else { return }
        // Search the new text along with the end of this run's earlier output, in case a message
        // was split between two reads.
        let tail = crashScanTail[id] ?? ""
        crashScanTail[id] = String((tail + text).suffix(200))
        noticeCrash(id, in: tail + text)
    }

    /// A game that overflows its stack inside Wine never recovers or shows a window. It just
    /// sits there looking like it's running, so stop it and say what happened.
    private func noticeCrash(_ id: UUID, in text: String) {
        guard running[id] != nil, !stopping.contains(id), let game = game(id) else { return }
        let crashed = ["Unhandled exception", "Unhandled page fault", "virtual_setup_exception stack overflow",
                       "nested exception on signal stack"].contains { text.contains($0) }
        if crashed, startedRecently(id), let next = nextSetup(for: game) {
            retryOnExit.insert(id)
            notices[id] = "The game crashed with \(Setup(engine: game.engine, graphics: game.graphics).title), so Decanter switched to \(next.title)."
            stop(game, retrying: true)
            return
        }
        if text.contains("virtual_setup_exception stack overflow") || text.contains("nested exception on signal stack") {
            stop(game)
            notices[id] = "The game crashed inside \(game.engine.title) and was stopped."
                + (nextStep(for: game).map { " Try \($0)." } ?? "")
                + " The log below has details."
        } else if text.contains("Unhandled exception") || text.contains("Unhandled page fault") {
            notices[id] = "The game crashed. Close Wine’s error window to return."
                + (nextStep(for: game).map { " If it keeps happening, try \($0)." } ?? "")
        }
    }

    /// What to suggest when a game crashes. For a CrossOver game on OpenGL, DXVK comes first,
    /// because Wine Staging can't run Direct3D 10/11 games on Apple Silicon at all. A game
    /// installed with Run Installer has to stay in the engine it was installed in.
    private func nextStep(for game: Game) -> String? {
        let other = Engine.owning(game.exePath) == nil ? Engine.allCases.first { $0 != game.engine } : nil
        switch (game.engine == .crossover && game.graphics == .opengl, other) {
        case (true, let other?): return "setting Graphics to DXVK, or the \(other.title) engine, under Options"
        case (true, nil): return "setting Graphics to DXVK under Options"
        case (false, let other?): return "the \(other.title) engine under Options"
        case (false, nil): return nil
        }
    }

    /// The .exe Decanter started has exited, but that isn't always the end of the game. Some
    /// games start from a launcher that opens the real game and quits (every Ren'Py game does).
    /// If nothing else is using the engine, the game is over once Wine has no programs left.
    private func launchedProgramExited(_ id: UUID, _ process: Process, status: Int32, after seconds: TimeInterval) {
        guard let wine = runningWine[id], !stopping.contains(id), !engineBusy(wine.engine, besides: id) else {
            gameExited(id, process, status: status, after: seconds)
            return
        }
        Task {
            _ = try? await Shell.run(wine.wineserver, ["-w"], environment: Wine.environment(for: wine))
            gameExited(id, process, status: status, after: seconds)
        }
    }

    private func gameExited(_ id: UUID, _ process: Process, status: Int32, after seconds: TimeInterval) {
        // This was already handled. Stop ends a game whose launcher has exited without waiting for Wine.
        guard running[id] === process else { return }
        let wine = runningWine[id]
        // How long the game itself ran, which for a game with a launcher is longer than `seconds`.
        let ran = launchedAt.removeValue(forKey: id).map { Date().timeIntervalSince($0) } ?? seconds
        running[id] = nil
        runningWine[id] = nil
        updateQuitHotKey()
        let stoppedByUser = stopping.remove(id) != nil
        let failedToStart = retryOnExit.remove(id) != nil || (!stoppedByUser && status != 0 && ran < Self.quickExit)
        // No setup can run a WebView2 game, and its notice already explains why.
        if failedToStart, let game = game(id), game.automatic, !Setup.usesWebView2(game.url) {
            if let next = nextSetup(for: game) {
                if notices[id] == nil {
                    notices[id] = "The game closed as it started with \(Setup(engine: game.engine, graphics: game.graphics).title), so Decanter switched to \(next.title)."
                }
                trySetup(next, for: id, after: wine)
            } else {
                // None of the others worked either, so go back to the one it started on.
                if let i = games.firstIndex(where: { $0.id == id }), let step = startStep[id] {
                    games[i].setupStep = step
                    applySetup(to: id)
                }
                notices[id] = "The game closed as it started with every setup Decanter tried. The log below may explain why."
            }
            return
        }
        if !stoppedByUser, status != 0, ran < 15, notices[id] == nil {
            notices[id] = "The game closed right away (exit code \(status))."
                + (game(id).flatMap(nextStep).map { " If it keeps happening, try \($0)." } ?? "")
                + " The log below may explain why."
        }
    }

    // MARK: Automatic setup

    /// A crash this soon after starting counts as the setup not working.
    private static let startupWindow: TimeInterval = 60
    /// So does exiting with an error this soon. Any later, and it could be a game that returns
    /// an error code when it's quit normally.
    private static let quickExit: TimeInterval = 20

    private func setups(for game: Game) -> [Setup] {
        Setup.candidates(for: game.url, madeWith: maker(of: game), stagingInstalled: engines[.wine] != nil)
    }

    /// What the game was made with. Finding out means reading files, so it's looked up once
    /// per .exe while Decanter is open.
    func maker(of game: Game) -> Maker? {
        if let known = makers[game.exePath] { return known }
        let found = Maker.of(game.url)
        // A missing file might come back later, so only remember the answer while the file is there.
        if FileManager.default.fileExists(atPath: game.exePath) { makers[game.exePath] = found }
        return found
    }

    /// Switches an automatic game to the setup it's currently up to.
    private func applySetup(to id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }), games[i].automatic else { return }
        let setups = setups(for: games[i])
        let setup = setups[min(games[i].setupStep, setups.count - 1)]
        if games[i].engine != setup.engine { games[i].engine = setup.engine }
        if games[i].graphics != setup.graphics { games[i].graphics = setup.graphics }
    }

    private func startedRecently(_ id: UUID) -> Bool {
        launchedAt[id].map { Date().timeIntervalSince($0) < Self.startupWindow } ?? false
    }

    /// The setup to try after this one fails, if the game is automatic and hasn't been
    /// through every setup since Play was pressed.
    private func nextSetup(for game: Game) -> Setup? {
        guard game.automatic, !Setup.usesWebView2(game.url) else { return nil }
        let setups = setups(for: game)
        guard setupRetries[game.id, default: 0] < setups.count - 1 else { return nil }
        return setups[(min(game.setupStep, setups.count - 1) + 1) % setups.count]
    }

    private func trySetup(_ setup: Setup, for id: UUID, after wine: WineBinary?) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].setupStep = setups(for: games[i]).firstIndex(of: setup) ?? 0
        setupRetries[id, default: 0] += 1
        // Show the game as starting while the old Wine closes, so Cancel still works.
        let token = UUID()
        startTokens[id] = token
        starting.insert(id)
        Task {
            // Let the old Wine finish closing, or the next start can't open a window. Only
            // briefly, though: another program may keep it busy.
            if let wine, !engineBusy(wine.engine, besides: id) {
                await Wine.waitUntilIdle(wine, timeout: 10)
            }
            guard startTokens[id] == token else { return }  // Someone pressed Cancel while we waited.
            finishStart(id, token)
            let notice = notices[id]
            if let game = game(id) { play(game, retry: true) }
            if notices[id] == nil { notices[id] = notice }  // play() clears the notice, but it should keep saying what's going on.
        }
    }

    /// Turning automatic back on starts again from the game's best setup.
    func setAutomatic(_ on: Bool, for id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].automatic = on
        if on {
            games[i].setupStep = 0
            applySetup(to: id)
        }
    }

    /// `retrying` means Decanter is stopping a game that crashed so it can try the next setup.
    func stop(_ game: Game, retrying: Bool = false) {
        if !retrying { retryOnExit.remove(game.id) }
        // Cancel a start that's under way. Its task may still be downloading or setting up,
        // but it won't launch anything.
        if starting.remove(game.id) != nil { startTokens[game.id] = nil }
        guard let process = running[game.id] else { return }
        stopping.insert(game.id)
        // Under CrossOver the game's window belongs to a child process, not the one we
        // launched, so end that too. The exception is when another running game has the same
        // .exe name (every RPG Maker game is Game.exe), because the window could be that one's.
        let exe = game.url.lastPathComponent.lowercased()
        let nameShared = games.contains { $0.id != game.id && running[$0.id] != nil && $0.url.lastPathComponent.lowercased() == exe }
        let apps = nameShared ? [] : gameApps(for: game)
        let launcherGone = !process.isRunning
        if !launcherGone { process.terminate() }
        apps.forEach { kill($0.processIdentifier, SIGTERM) }
        if let wine = runningWine[game.id], !engineBusy(wine.engine, besides: game.id) {
            // Nothing else is using this engine, so clear out its helper processes too.
            Wine.killAll(wine)
        }
        // Its launcher has already exited, so nothing else will report the game ending.
        if launcherGone { gameExited(game.id, process, status: 0, after: 0) }
        // Anything that ignores the polite request is forced to quit after a few seconds.
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
            apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    /// Whether anything besides this game is using the engine.
    private func engineBusy(_ engine: Engine, besides id: UUID) -> Bool {
        running.keys.contains { $0 != id && runningWine[$0]?.engine == engine }
            || starting.contains { $0 != id && game($0)?.engine == engine }
            || (installerRunning && engine == .default)
    }

    func stopAll() {
        startTokens.removeAll()
        starting.removeAll()
        retryOnExit.removeAll()
        stopping.formUnion(running.keys)
        for game in games where running[game.id] != nil {
            gameApps(for: game).forEach { kill($0.processIdentifier, SIGTERM) }
        }
        running.values.forEach { $0.terminate() }
        engines.values.forEach(Wine.killAll)
        installerRunning = false
    }

    /// Pressing ⌘Q in Decanter quits the games too, since they shouldn't outlive the launcher.
    /// The wineserver -k processes started here finish their job even after Decanter has exited.
    func quitAllGamesForExit() {
        guard !running.isEmpty || !starting.isEmpty else { return }
        stopAll()
    }

    // MARK: ⌘Q while playing

    /// The macOS apps showing a game's windows, matched by the game's .exe name, which is
    /// how Wine names them.
    private func gameApps(for game: Game) -> [NSRunningApplication] {
        let exe = game.url.lastPathComponent.lowercased()
        return NSWorkspace.shared.runningApplications.filter {
            $0.localizedName?.lowercased() == exe || $0.executableURL?.lastPathComponent.lowercased() == exe
        }
    }

    /// The running games an app belongs to. When a game's window belongs to a different .exe
    /// (a launcher's, or Unreal's -Shipping.exe), there's no telling which game it is, so any
    /// Wine app counts as all of them.
    func runningGames(shownBy app: NSRunningApplication) -> [Game] {
        let playing = games.filter { running[$0.id] != nil }
        guard !playing.isEmpty, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return [] }
        let names = [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0?.lowercased() }
        let exact = playing.filter { names.contains($0.url.lastPathComponent.lowercased()) }
        if !exact.isEmpty { return exact }
        let path = app.executableURL?.path ?? ""
        let isWine = names.contains { $0.hasSuffix(".exe") } || path.contains("/winetemp-")
            || Engine.allCases.contains { path.hasPrefix($0.installDir.path) }
        return isWine ? playing : []
    }

    private func updateQuitHotKey() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        quitHotKey.isEnabled = !runningGames(shownBy: front).isEmpty
    }

    func quitFrontmostGame() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        runningGames(shownBy: front).forEach { stop($0) }
        quitHotKey.isEnabled = false
    }

    // MARK: Installers and tools

    func showInstallerPanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Windows installer (setup.exe or .msi)"
        panel.allowedContentTypes = Self.windowsTypes
        if panel.runModal() == .OK, let url = panel.url { runInstaller(url) }
    }

    /// Runs an installer in the default engine, then asks which installed .exe to add.
    func runInstaller(_ url: URL) {
        guard !installerRunning else { return }
        installerRunning = true
        Task {
            defer { installerRunning = false }
            do {
                let wine = try await prepare(.default)
                let before = programFolders(wine.engine)
                let args = url.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", url.path] : [url.path]
                try await Wine.runAndWait(wine, args, cwd: url.deletingLastPathComponent())
                // Many installers start the real setup and quit, so wait for whatever they left
                // running. Don't wait if a game is using this Windows environment, though.
                let gameUsesEngine = running.keys.contains { runningWine[$0]?.engine == wine.engine }
                    || starting.contains { game($0)?.engine == wine.engine }
                if !gameUsesEngine { await Wine.waitUntilIdle(wine, timeout: 600) }
                let newFolders = programFolders(wine.engine).subtracting(before)
                installerRunning = false
                chooseInstalledGame(in: wine.engine, startingIn: newFolders.count == 1 ? newFolders.first : nil)
            } catch {
                alert = "The installer couldn’t run: \(error.localizedDescription)"
            }
        }
    }

    private func programFolders(_ engine: Engine) -> Set<URL> {
        let fm = FileManager.default
        let roots = ["Program Files", "Program Files (x86)", "GOG Games", "Games"].map {
            engine.driveC.appendingPathComponent($0)
        }
        return Set(roots.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] })
    }

    private func chooseInstalledGame(in engine: Engine, startingIn folder: URL?) {
        let fm = FileManager.default
        let panel = NSOpenPanel()
        panel.message = "Installer finished. Choose the game’s .exe to add it to your library."
        panel.prompt = "Add Game"
        panel.allowedContentTypes = Self.windowsTypes
        panel.directoryURL = folder ?? [
            engine.driveC.appendingPathComponent("Program Files (x86)"),
            engine.driveC.appendingPathComponent("Program Files"),
        ].first { fm.fileExists(atPath: $0.path) }
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { addToLibrary(url, engine: engine) }
    }

    func openWineTool(_ tool: String, engine: Engine) {
        Task {
            do {
                let wine = try await prepare(engine)
                let p = Wine.process(wine, [tool])
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    func showDriveC(_ engine: Engine) {
        Task {
            do {
                try await prepare(engine)
                NSWorkspace.shared.open(engine.driveC)
            } catch {
                alert = error.localizedDescription
            }
        }
    }

    /// Deletes an engine's Windows environment, along with the programs, saves and settings in
    /// it. The folder is moved aside straight away and deleted in the background. Anything that
    /// needs the environment in the meantime waits, then makes a fresh one.
    func resetPrefix(_ engine: Engine) {
        guard resetTasks[engine] == nil else { return }
        for game in games where game.engine == engine && (running[game.id] != nil || starting.contains(game.id)) {
            stop(game)
        }
        installs[engine] = .working("Resetting \(engine.title)’s Windows environment…", nil)
        resetTasks[engine] = Task {
            if let wine = engines[engine] {
                _ = try? await Shell.run(wine.wineserver, ["-k"], environment: Wine.environment(for: wine))
            }
            let fm = FileManager.default
            let prefix = engine.prefix
            if fm.fileExists(atPath: prefix.path) {
                let aside = prefix.deletingLastPathComponent()
                    .appendingPathComponent(".\(prefix.lastPathComponent)-reset-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: prefix, to: aside)
                    Task.detached(priority: .background) { try? FileManager.default.removeItem(at: aside) }
                } catch {
                    alert = "Couldn’t reset: \(error.localizedDescription)"
                }
            }
            installs[engine] = nil
            resetTasks[engine] = nil
        }
    }
}
