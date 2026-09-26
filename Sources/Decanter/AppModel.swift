import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Game: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var exePath: String
    var engine = Engine.default
    var graphics = Graphics.default
    /// Decanter picks the engine and graphics (see Setup.candidates), and moves on to the next
    /// setup when the game closes or crashes as it starts. Picking either by hand turns it off.
    var automatic = true
    /// How far down Setup.candidates an automatic game has had to go.
    var setupStep = 0
    var arguments = ""
    var virtualDesktop = false
    var desktopSize = "1280x720"
    var added = Date()
    var lastPlayed: Date?

    init(name: String, exePath: String, engine: Engine = .default) {
        self.name = name
        self.exePath = exePath
        self.engine = engine
    }

    // Tolerates library files written by older versions with fewer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        // Games installed with Run Installer live in the support folder, which has moved.
        exePath = AppPaths.migrated(try c.decode(String.self, forKey: .exePath))
        if c.contains(.engine) {
            engine = (try? c.decode(Engine.self, forKey: .engine)) ?? Engine.owning(exePath) ?? .default
        } else {
            // Saved by 1.0, which only had Wine Staging. Staying there keeps the game's
            // saves and settings, which live in that engine's Windows environment.
            engine = .wine
        }
        graphics = (try? c.decodeIfPresent(Graphics.self, forKey: .graphics)) ?? .default
        // Before 1.2 the engine was only ever Wine Staging because 1.0 had nothing else or
        // because the player picked it, so leave those as they are.
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic)
            ?? (engine == .crossover || Engine.owning(exePath) != nil)
        setupStep = try c.decodeIfPresent(Int.self, forKey: .setupStep) ?? 0
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        virtualDesktop = try c.decodeIfPresent(Bool.self, forKey: .virtualDesktop) ?? false
        desktopSize = try c.decodeIfPresent(String.self, forKey: .desktopSize) ?? "1280x720"
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }

    var url: URL { URL(fileURLWithPath: exePath) }
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

    /// Installed engines. A missing key means that engine isn't installed.
    var engines: [Engine: WineBinary] = [:]
    var versions: [Engine: String] = [:]
    /// Download/setup progress per engine. A missing key means idle.
    var installs: [Engine: SetupState] = [:]
    var rosettaMissing = false
    /// True from the first-run screen's Download until that engine is ready (or while it
    /// shows a failure), so the screen stays up through setup. Settings reinstalls don't set it.
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
    /// A newer release than this one, until the player dismisses it.
    var update: Updates.Release?
    var updateStatus = Updates.Status.unknown

    @ObservationIgnored private var runningWine: [UUID: WineBinary] = [:]
    @ObservationIgnored private var launchedAt: [UUID: Date] = [:]
    /// Setups tried by itself since the player last pressed Play, per game.
    @ObservationIgnored private var setupRetries: [UUID: Int] = [:]
    /// Games stopped after crashing as they started, to relaunch with the next setup.
    @ObservationIgnored private var retryOnExit: Set<UUID> = []
    @ObservationIgnored private var stopping: Set<UUID> = []
    @ObservationIgnored private var cancelledStarts: Set<UUID> = []
    @ObservationIgnored private var iconCache: [UUID: NSImage] = [:]
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

    /// Every launch checks quietly, and says nothing about errors or a version the player
    /// skipped. Check for Updates… always answers: from the menu with an alert, from the
    /// About window in place.
    func checkForUpdates(userInitiated: Bool = false, answerInAbout: Bool = false) {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        let alerts = userInitiated && !answerInAbout
        Task {
            do {
                if let release = try await Updates.latest(), Updates.isNewer(release.version, than: Updates.currentVersion) {
                    updateStatus = .available(release)
                    let skipped = UserDefaults.standard.string(forKey: "skippedVersion") == release.version
                    if !answerInAbout, userInitiated || !skipped { update = release }
                } else {
                    updateStatus = .upToDate
                    if alerts { alert = "Decanter \(Updates.currentVersion) is the latest version." }
                }
            } catch {
                updateStatus = .failed
                if alerts { alert = "Couldn’t check for updates. Check your internet connection and try again." }
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
        // Read game by game, so one unreadable entry doesn't cost the rest.
        struct Entry: Decodable {
            let game: Game?
            init(from decoder: Decoder) throws { game = try? Game(from: decoder) }
        }
        let entries = try? JSONDecoder().decode([Entry].self, from: data)
        let saved = entries?.compactMap(\.game) ?? []
        if saved.count != entries?.count || Self.rewriteLoses(data, saved) {
            let stamp = Date().formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
            let copy = AppPaths.support.appendingPathComponent("library-\(stamp).json")
            guard (try? FileManager.default.copyItem(at: AppPaths.library, to: copy)) != nil else { return }
            alert = "Part of your game library couldn’t be read, possibly because a newer Decanter saved it. The original is kept as \(copy.lastPathComponent) in Decanter’s Application Support folder."
        }
        games = saved
    }

    /// Whether saving `games` over `data` would drop fields or engines this build doesn't know.
    private static func rewriteLoses(_ data: Data, _ games: [Game]) -> Bool {
        guard let old = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let new = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(games))) as? [[String: Any]],
              old.count == new.count else { return true }
        return zip(old, new).contains { old, new in
            old.keys.contains { new[$0] == nil } || old["engine"].map { $0 as? String != new["engine"] as? String } == true
        }
    }

    private func saveLibrary() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(games).write(to: AppPaths.library, options: .atomic)
    }

    /// "Game.exe" in "Cool Game/bin/x64" becomes "Cool Game".
    static func defaultName(for url: URL) -> String {
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

    static func looksLikeInstaller(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("unins") { return false }
        return url.pathExtension.lowercased() == "msi" || name.contains("setup") || name.contains("install")
    }

    // MARK: Engines

    func installState(_ engine: Engine) -> SetupState { installs[engine] ?? .idle }

    /// The first-run screen shows when no engine is installed at all (someone who already
    /// has Wine Staging goes straight to their library; CrossOver downloads on first Play).
    var needsSetup: Bool { engines.isEmpty || firstRunSetup }

    /// The engine the menu commands act on: the selected game's, else the default.
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

    /// The first-run screen's Download / Try Again.
    func setUpFirstRun() {
        firstRunSetup = true
        Task {
            if (try? await prepare(.default)) != nil { firstRunSetup = false }
        }
    }

    /// Makes an engine ready to run games: downloads it if needed, then creates its Windows
    /// environment. Progress and failures go to `installs[engine]`, which stays "working"
    /// until both steps finish, so the UI never flickers between them. Concurrent callers
    /// share one run.
    @discardableResult
    private func prepare(_ engine: Engine, reinstall: Bool = false) async throws -> WineBinary {
        // Join a run already under way first, so nobody launches a game from an engine
        // that's being replaced or a prefix that's half made.
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

    /// `retry` is Decanter trying the next setup by itself, rather than the player pressing Play.
    func play(_ game: Game, retry: Bool = false) {
        guard running[game.id] == nil, !starting.contains(game.id) else { return }
        if !retry { setupRetries[game.id] = 0 }
        applySetup(to: game.id)
        guard let game = self.game(game.id) else { return }
        // Rosetta may have been installed from Settings since the last check.
        if rosettaMissing { rosettaMissing = !WineLocator.rosettaAvailable }
        guard !rosettaMissing else {
            notices[game.id] = "Wine needs Rosetta 2. Install it from the setup screen or Settings, then try again."
            return
        }
        guard FileManager.default.fileExists(atPath: game.exePath) else {
            notices[game.id] = "Can’t find the game file. Was it moved or deleted?"
            return
        }
        // Some games only use WebView2 for an optional web page, so say so rather than refuse.
        notices[game.id] = Setup.usesWebView2(game.url)
            ? "This game uses Microsoft Edge WebView2, which doesn’t work in Wine yet. If it asks to install WebView2, it probably can’t run."
            : nil
        logs[game.id] = ""
        cancelledStarts.remove(game.id)
        starting.insert(game.id)
        Task {
            defer { starting.remove(game.id) }
            do {
                let wine = try await prepare(game.engine)
                await installBundledRuntimes(for: game, with: wine)
                if game.graphics == .dxvk { await Wine.installDXVK(wine) }
                // Cancelled, removed, force-quit or reset while getting ready.
                guard cancelledStarts.remove(game.id) == nil, let current = self.game(game.id) else { return }
                // Launch options may have changed while it was getting ready.
                running[game.id] = try launch(current, with: wine)
                runningWine[game.id] = wine
                launchedAt[game.id] = Date()
                updateQuitHotKey()
                if let i = games.firstIndex(where: { $0.id == game.id }) { games[i].lastPlayed = Date() }
            } catch {
                notices[game.id] = "Couldn’t start the game: \(error.localizedDescription)"
            }
        }
    }

    /// Runtime installers games often ship next to their .exe, with their silent-install flags.
    private static let runtimeInstallers: [(name: String, matches: (String) -> Bool, args: [String])] = [
        ("OpenAL", { $0 == "oalinst.exe" }, ["/s"]),
        ("Visual C++ runtime", { $0.hasPrefix("vcredist") || $0.hasPrefix("vc_redist") }, ["/q", "/norestart"]),
    ]

    /// Silently installs any bundled runtimes (e.g. oalinst.exe for OpenAL) the first time
    /// they're seen. Remembered inside the prefix, so resetting it starts fresh.
    private func installBundledRuntimes(for game: Game, with wine: WineBinary) async {
        let record = wine.prefix.appendingPathComponent("decanter-runtimes.txt")
        let legacyRecord = wine.prefix.appendingPathComponent("yeobgamer-runtimes.txt")
        try? FileManager.default.moveItem(at: legacyRecord, to: record)  // Named before the rename.
        var done = Set(((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        let found = Self.runtimeInstallers(near: game.url).filter { !done.contains($0.key) }

        for item in found {
            notices[game.id] = "Installing \(item.name) (included with the game)…"
            // A silent installer that's still going after three minutes is stuck; don't
            // let it block the game forever.
            let status = try? await Wine.runAndWait(wine, [item.url.path] + item.args,
                                                    cwd: item.url.deletingLastPathComponent(), timeout: 180)
            let result = status.map { "exit \($0)" } ?? "timed out"
            appendLog(game.id, "Installed \(item.name) from \(item.url.lastPathComponent) (\(result))\n")
            done.insert(item.key)
        }
        if !found.isEmpty {
            try? done.sorted().joined(separator: "\n").write(to: record, atomically: true, encoding: .utf8)
            notices[game.id] = nil
        }
    }

    /// Looks up to three folders deep beside the game's .exe for known runtime installers.
    private static func runtimeInstallers(near exe: URL) -> [(name: String, url: URL, args: [String], key: String)] {
        // A game .exe sitting loose in one of these doesn't own the installers around it.
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
        if game.virtualDesktop {
            // Explorer starts the program itself, so it needs a Windows-style path.
            args += ["explorer", "/desktop=Decanter,\(game.desktopSize)"]
        }
        if exe.pathExtension.lowercased() == "msi" { args += ["msiexec", "/i"] }
        args.append(game.virtualDesktop ? Wine.windowsPath(exe) : exe.path)
        args += splitArguments(game.arguments)

        // Run from the game's folder: most games load their files relative to it.
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
        appendLog(id, "[\(wine.engine.title)\(version)] $ wine \(args.joined(separator: " "))\n")
        try process.run()
        return process
    }

    private func appendLog(_ id: UUID, _ text: String) {
        let previous = logs[id] ?? ""
        var log = previous + text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
        logs[id] = log
        // With the end of the last read, in case a message was split between reads.
        noticeCrash(id, in: String(previous.suffix(200)) + text)
    }

    /// A game that overflows its stack inside Wine never recovers or shows a window;
    /// it just sits there looking like it's running. Stop it and say what happened.
    private func noticeCrash(_ id: UUID, in text: String) {
        guard running[id] != nil, !stopping.contains(id), let game = game(id) else { return }
        let crashed = ["Unhandled exception", "Unhandled page fault", "virtual_setup_exception stack overflow",
                       "nested exception on signal stack"].contains { text.contains($0) }
        if crashed, startedRecently(id), let next = nextSetup(for: game) {
            retryOnExit.insert(id)
            notices[id] = "The game crashed with \(Setup(engine: game.engine, graphics: game.graphics).title), so Decanter is trying \(next.title)…"
            stop(game)
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

    /// What to try when a game crashes. DXVK first for a CrossOver game on OpenGL: Wine Staging
    /// can't run Direct3D 10/11 games on Apple Silicon at all. A game installed with Run
    /// Installer has to stay in the engine it was installed in.
    private func nextStep(for game: Game) -> String? {
        let other = Engine.owning(game.exePath) == nil ? Engine.allCases.first { $0 != game.engine } : nil
        switch (game.engine == .crossover && game.graphics == .opengl, other) {
        case (true, let other?): return "setting Graphics to DXVK, or the \(other.title) engine, under Options"
        case (true, nil): return "setting Graphics to DXVK under Options"
        case (false, let other?): return "the \(other.title) engine under Options"
        case (false, nil): return nil
        }
    }

    /// The .exe Decanter started has exited, which isn't always the end of the game: some
    /// start from a launcher that opens the real game and quits (every Ren'Py game does).
    /// With nothing else running in the engine, the game is over once Wine has no programs left.
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
        // Already handled: Stop ends a game whose launcher has exited without waiting for Wine.
        guard running[id] === process else { return }
        let wine = runningWine[id]
        // How long the game itself ran, which for a game with a launcher is longer than `seconds`.
        let ran = launchedAt.removeValue(forKey: id).map { Date().timeIntervalSince($0) } ?? seconds
        running[id] = nil
        runningWine[id] = nil
        updateQuitHotKey()
        let stoppedByUser = stopping.remove(id) != nil
        let failedToStart = retryOnExit.remove(id) != nil || (!stoppedByUser && status != 0 && ran < Self.quickExit)
        if failedToStart, let game = game(id), game.automatic {
            if let next = nextSetup(for: game) {
                if notices[id] == nil {
                    notices[id] = "The game closed as it started with \(Setup(engine: game.engine, graphics: game.graphics).title), so Decanter is trying \(next.title)…"
                }
                trySetup(next, for: id, after: wine)
            } else {
                notices[id] = "The game closed as it started with every setup Decanter has. The log below may explain why."
            }
            return
        }
        if !stoppedByUser, status != 0, seconds < 15, notices[id] == nil {
            notices[id] = "The game closed right away (exit code \(status))."
                + (game(id).flatMap(nextStep).map { " If it keeps happening, try \($0)." } ?? "")
                + " The log below may explain why."
        }
    }

    // MARK: Automatic setup

    /// A crash this soon after starting counts as the setup not working.
    private static let startupWindow: TimeInterval = 60
    /// So does exiting with an error this soon: any later could be a game that returns an
    /// error code when quit normally.
    private static let quickExit: TimeInterval = 20

    /// Points an automatic game at the setup it's up to.
    private func applySetup(to id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }), games[i].automatic else { return }
        let setups = Setup.candidates(for: games[i].url)
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
        let setups = Setup.candidates(for: game.url)
        guard setupRetries[game.id, default: 0] < setups.count - 1 else { return nil }
        return setups[(min(game.setupStep, setups.count - 1) + 1) % setups.count]
    }

    private func trySetup(_ setup: Setup, for id: UUID, after wine: WineBinary?) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        let setups = Setup.candidates(for: games[i].url)
        games[i].setupStep = setups.firstIndex(of: setup) ?? 0
        setupRetries[id, default: 0] += 1
        Task {
            // Let the old Wine finish closing, or the next start can't open a window.
            if let wine, !engineBusy(wine.engine, besides: id) {
                _ = try? await Shell.run(wine.wineserver, ["-w"], environment: Wine.environment(for: wine))
            }
            let notice = notices[id]
            if let game = game(id) { play(game, retry: true) }
            if notices[id] == nil { notices[id] = notice }  // play() clears it; keep saying what's going on.
        }
    }

    /// Automatic back on starts again from the best setup for the game.
    func setAutomatic(_ on: Bool, for id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        games[i].automatic = on
        if on {
            games[i].setupStep = 0
            applySetup(to: id)
        }
    }

    func stop(_ game: Game) {
        if starting.contains(game.id) { cancelledStarts.insert(game.id) }
        guard let process = running[game.id] else { return }
        stopping.insert(game.id)
        // Under CrossOver the game's window belongs to a child process, not the one we
        // launched, so end that too.
        let apps = gameApps(for: game)
        let launcherGone = !process.isRunning
        if !launcherGone { process.terminate() }
        apps.forEach { kill($0.processIdentifier, SIGTERM) }
        if let wine = runningWine[game.id], !engineBusy(wine.engine, besides: game.id) {
            // Nothing else runs on this engine, so also clear out its helper processes.
            Wine.killAll(wine)
        }
        // Its launcher has already exited, so nothing else will report the game ending.
        if launcherGone { gameExited(game.id, process, status: 0, after: 0) }
        // Anything that ignored the polite request gets forced after a few seconds.
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
        cancelledStarts.formUnion(starting)
        stopping.formUnion(running.keys)
        for game in games where running[game.id] != nil {
            gameApps(for: game).forEach { kill($0.processIdentifier, SIGTERM) }
        }
        running.values.forEach { $0.terminate() }
        engines.values.forEach(Wine.killAll)
        installerRunning = false
    }

    /// ⌘Q in Decanter: games shouldn't outlive the launcher. The wineserver -k processes
    /// started here finish their job even after Decanter has exited.
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

    /// The running games an app belongs to. A game played "inside a window" shows up as
    /// Wine's explorer.exe, which can't be told apart, so any Wine app means all of them.
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
        runningGames(shownBy: front).forEach(stop)
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

    /// Deletes an engine's Windows environment (installed programs, saves stored in it, settings).
    func resetPrefix(_ engine: Engine) {
        for game in games where game.engine == engine && (running[game.id] != nil || starting.contains(game.id)) {
            stop(game)
        }
        Task {
            if let wine = engines[engine] {
                _ = try? await Shell.run(wine.wineserver, ["-k"], environment: Wine.environment(for: wine))
            }
            do {
                if FileManager.default.fileExists(atPath: engine.prefix.path) {
                    try FileManager.default.removeItem(at: engine.prefix)
                }
            } catch {
                alert = "Couldn’t reset: \(error.localizedDescription)"
            }
        }
    }
}
