import Foundation

// Everything that talks to Wine lives here. Foundation-only on purpose, so it
// stays independent of the UI.

enum AppPaths {
    private static let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    /// Decanter was called Yeobgamer up to 1.1, and kept everything here.
    private static let legacy = base.appendingPathComponent("Yeobgamer", isDirectory: true)

    /// The first launch after the rename moves the Yeobgamer folder here, with its library,
    /// engines and Windows environments (and the saves in them), and leaves a link in its
    /// place for any old copy of the app.
    static let support: URL = {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("Decanter", isDirectory: true)
        let legacyIsFolder = (try? fm.attributesOfItem(atPath: legacy.path)[.type] as? FileAttributeType) == .typeDirectory
        if !fm.fileExists(atPath: dir.path), legacyIsFolder {
            do {
                try fm.moveItem(at: legacy, to: dir)
                try? fm.createSymbolicLink(at: legacy, withDestinationURL: dir)
            } catch {
                return legacy  // Keep using it where it is rather than start over empty.
            }
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A path saved inside the old Yeobgamer folder, pointed at the same file in `support`.
    static func migrated(_ path: String) -> String {
        let old = legacy.path + "/"
        guard support != legacy, path.hasPrefix(old) else { return path }
        return support.path + "/" + path.dropFirst(old.count)
    }

    static var icons: URL { support.appendingPathComponent("Icons", isDirectory: true) }
    static var library: URL { support.appendingPathComponent("library.json") }

    static func icon(for id: UUID) -> URL { icons.appendingPathComponent("\(id.uuidString).ico") }
}

/// The Wine builds Decanter can run games with. Each has its own folder and its own
/// Windows environment (prefix), since a prefix doesn't move cleanly between Wine versions.
enum Engine: String, Codable, CaseIterable, Identifiable {
    /// CodeWeavers' CrossOver 24 Wine, built by the Sikarugir project. Runs 32-bit games on
    /// Apple Silicon that crash in upstream Wine, such as GameMaker 8 games.
    case crossover
    /// Upstream Wine Staging (Gcenx's macOS builds): the newest Wine.
    case wine

    static let `default` = Engine.crossover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crossover: "CrossOver 24"
        case .wine: "Wine Staging"
        }
    }

    var summary: String {
        switch self {
        case .crossover: "Best for most games, especially older 32-bit ones."
        case .wine: "The newest Wine. Try it if a game has problems with CrossOver 24. Games made with DirectX 10 or 11, including most Unity games, need CrossOver 24."
        }
    }

    var downloadSize: String {
        switch self {
        case .crossover: "about 260 MB"
        case .wine: "about 190 MB"
        }
    }

    /// Where Decanter keeps its own download of this engine.
    var installDir: URL {
        switch self {
        case .crossover: AppPaths.support.appendingPathComponent("Engines/CrossOver", isDirectory: true)
        case .wine: AppPaths.support.appendingPathComponent("Wine", isDirectory: true)
        }
    }

    /// The Windows environment (WINEPREFIX) this engine's games run in.
    var prefix: URL {
        switch self {
        case .crossover: AppPaths.support.appendingPathComponent("Prefix-CrossOver", isDirectory: true)
        case .wine: AppPaths.support.appendingPathComponent("Prefix", isDirectory: true)
        }
    }

    var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }

    /// The engine whose Windows environment contains this file, e.g. a game that was
    /// installed with Run Installer. It has to keep running in that engine.
    static func owning(_ path: String) -> Engine? {
        allCases.first { path.hasPrefix($0.prefix.path + "/") }
    }
}

/// How a game on the CrossOver engine draws with Direct3D 10 and 11. Direct3D 8 and 9
/// always go through Wine's own Direct3D on OpenGL.
enum Graphics: String, Codable, CaseIterable, Identifiable {
    /// Wine's own Direct3D on OpenGL. It stops at feature level 10.1, but in testing it ran
    /// every Unity, GameMaker, MonoGame and Ren'Py game tried.
    case opengl
    /// DXVK turns Direct3D into Vulkan, which MoltenVK runs on Metal. It offers feature
    /// level 11, which some newer Unity games need, but it showed a black screen for several
    /// games that run fine on OpenGL, including Ren'Py (which draws through ANGLE).
    case dxvk

    static let `default` = Graphics.opengl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dxvk: "DXVK"
        case .opengl: "OpenGL"
        }
    }
}

enum WineError: LocalizedError {
    case notFound
    case downloadFailed(Int)
    case unpackFailed
    case prefixFailed

    var errorDescription: String? {
        switch self {
        case .notFound: "Wine could not be found after installing."
        case .downloadFailed(let code): "The download failed (HTTP \(code))."
        case .unpackFailed: "The Wine download could not be unpacked."
        case .prefixFailed: "Wine could not create its Windows environment."
        }
    }
}

struct WineBinary: Equatable {
    let engine: Engine
    let wine: URL
    /// Folder of support libraries (FreeType, SDL, MoltenVK…) the engine loads by name.
    var libraries: URL?

    var binDir: URL { wine.deletingLastPathComponent() }
    var wineserver: URL { binDir.appendingPathComponent("wineserver") }
    var prefix: URL { engine.prefix }
}

// MARK: - Finding Wine

enum WineLocator {
    static func find(_ engine: Engine, customPath: String) -> WineBinary? {
        switch engine {
        case .crossover:
            let wine = engine.installDir.appendingPathComponent("wswine.bundle/bin/wine")
            guard FileManager.default.isExecutableFile(atPath: wine.path) else { return nil }
            return WineBinary(engine: .crossover, wine: wine, libraries: engine.installDir)
        case .wine:
            // Custom path first, then Decanter's own copy, then common system installs.
            if !customPath.isEmpty, let custom = binary(at: URL(fileURLWithPath: customPath)) {
                return custom
            }
            return candidates().lazy.compactMap(binary(at:)).first
        }
    }

    /// Accepts a wine executable, its bin folder, or a "Wine *.app" bundle.
    static func binary(at url: URL) -> WineBinary? {
        let fm = FileManager.default
        var url = url
        if url.pathExtension == "app" {
            url = url.appendingPathComponent("Contents/Resources/wine/bin/wine")
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            url = url.appendingPathComponent("wine")
        }
        let resolved = url.resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: resolved.path) else { return nil }
        return WineBinary(engine: .wine, wine: resolved)
    }

    private static func managedApps() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Engine.wine.installDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" }
    }

    private static func candidates() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        for dir in ["/Applications", home + "/Applications"] {
            for name in ["Wine Staging", "Wine Stable", "Wine Devel", "Wine Crossover"] {
                paths.append("\(dir)/\(name).app/Contents/Resources/wine/bin/wine")
                paths.append("\(dir)/\(name).app/Contents/Resources/wine/bin/wine64")
            }
        }
        paths += [
            "/opt/homebrew/bin/wine", "/usr/local/bin/wine",
            "/opt/homebrew/bin/wine64", "/usr/local/bin/wine64",
            home + "/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64",
        ]
        return managedApps() + paths.map { URL(fileURLWithPath: $0) }
    }

    /// Wine for macOS is an Intel build, so Apple Silicon Macs need Rosetta 2.
    static var rosettaAvailable: Bool {
        #if arch(arm64)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
        #else
        return true
        #endif
    }
}

// MARK: - Running Wine

enum Wine {
    static func environment(for wine: WineBinary, graphics: Graphics = .opengl) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = wine.prefix.path
        env["WINEDEBUG"] = "fixme-all"
        // Stop Wine from littering ~/Applications and the Desktop with shortcuts.
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        env["PATH"] = wine.binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // No "Wine configuration is being updated" popup while a prefix is created.
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        // MoltenVK otherwise prints ~150 lines of GPU info into every game's log.
        env["MVK_CONFIG_LOG_LEVEL"] = "1"
        // .NET (XNA/FNA) games misbehave under Rosetta with write-xor-execute on.
        env["DOTNET_EnableWriteXorExecute"] = "0"
        if wine.engine == .crossover {
            // Never CrossOver 24's own choice for Direct3D 10/11, Wine's Vulkan renderer: it
            // can't make a D3D 10/11 device on MoltenVK, so Unity games crash at startup.
            // Wine's OpenGL renderer draws Direct3D 8/9 and, with Graphics set to OpenGL, 10/11.
            env["WINE_D3D_CONFIG"] = "renderer=gl"
            // DXVK's DLLs sit in the Windows environment (see installDXVK); this picks them or Wine's.
            env["WINEDLLOVERRIDES", default: ""] += ";d3d11,dxgi,d3d10core=" + (graphics == .dxvk ? "n,b" : "b")
            if graphics == .dxvk {
                env["DXVK_ASYNC"] = "1"  // Compile shaders in the background rather than stutter.
                env["DXVK_LOG_PATH"] = "none"  // It otherwise writes log files into the game's folder.
                env["DXVK_STATE_CACHE_PATH"] = #"C:\decanter\dxvk-cache"#
            }
        }
        if let libraries = wine.libraries {
            // Without these, Wine runs with no fonts, sound, controllers, MP3 or video, and
            // some installers hang. Mirrors the Sikarugir launcher. Only works because Wine
            // is launched directly: macOS strips DYLD_* variables when a system binary
            // (bash, perl…) starts it.
            let gstreamer = libraries.appendingPathComponent("GStreamer.framework/Libraries")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = [libraries.path, gstreamer.path, "/usr/lib"].joined(separator: ":")
            env["GST_PLUGIN_PATH"] = gstreamer.appendingPathComponent("gstreamer-1.0").path
        }
        return env
    }

    static func process(_ wine: WineBinary, _ arguments: [String], cwd: URL? = nil,
                        graphics: Graphics = .opengl) -> Process {
        let p = Process()
        p.executableURL = wine.wine
        p.arguments = arguments
        p.environment = environment(for: wine, graphics: graphics)
        if let cwd { p.currentDirectoryURL = cwd }
        return p
    }

    /// Copies DXVK from the CrossOver engine's renderer folder into its Windows environment,
    /// where it's only used when Graphics is set to DXVK. Sikarugir builds these DLLs with
    /// Wine's "builtin" marker, which makes Wine load its own d3d11 in their place, so the
    /// copies have the marker cleared. Runs before each DXVK launch: `wineboot --update`
    /// puts Wine's files back.
    static func installDXVK(_ wine: WineBinary) async {
        guard wine.engine == .crossover, let libraries = wine.libraries else { return }
        await Task.detached {
            let source = libraries.appendingPathComponent("renderer/dxvk/wine")
            let windows = wine.prefix.appendingPathComponent("drive_c/windows")
            let marker = Data("Wine builtin DLL".utf8)
            for (arch, folder) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
                for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll"] {
                    guard var data = try? Data(contentsOf: source.appendingPathComponent("\(arch)/\(dll)")) else { continue }
                    if data.count > 0x60, data[0x40..<0x50] == marker {
                        data.replaceSubrange(0x40..<0x60, with: Data(count: 0x20))
                    }
                    let target = windows.appendingPathComponent("\(folder)/\(dll)")
                    if (try? Data(contentsOf: target)) != data { try? data.write(to: target, options: .atomic) }
                }
            }
            try? FileManager.default.createDirectory(
                at: wine.prefix.appendingPathComponent("drive_c/decanter/dxvk-cache"), withIntermediateDirectories: true)
        }.value
    }

    /// Runs Wine and waits for it to exit. Output is discarded: Wine's background
    /// server inherits the pipes and would keep them open long after. With a timeout,
    /// a program that's still running afterwards is killed and nil is returned.
    @discardableResult
    static func runAndWait(_ wine: WineBinary, _ arguments: [String], cwd: URL? = nil,
                           timeout: TimeInterval? = nil) async throws -> Int32? {
        let p = process(wine, arguments, cwd: cwd)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard let timeout else { return try await Shell.wait(for: p) }

        final class Flag: @unchecked Sendable { var raised = false }
        let timedOut = Flag()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if p.isRunning {
                timedOut.raised = true
                p.terminate()
            }
        }
        defer { watchdog.cancel() }
        let status = try await Shell.wait(for: p)
        return timedOut.raised ? nil : status
    }

    static func prefixReady(_ engine: Engine) -> Bool {
        FileManager.default.fileExists(atPath: engine.prefix.appendingPathComponent("system.reg").path)
    }

    /// Creates the Windows environment on first use (takes a minute or so).
    static func preparePrefix(_ wine: WineBinary) async throws {
        guard !prefixReady(wine.engine) else { return }
        try await runAndWait(wine, ["wineboot", "--init"])
        // The registry files only appear once the Wine server shuts down. If waiting on
        // it directly fails, poll for them instead.
        if (try? await Shell.run(wine.wineserver, ["-w"], environment: environment(for: wine))) == nil {
            for _ in 0..<120 where !prefixReady(wine.engine) {
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard prefixReady(wine.engine) else { throw WineError.prefixFailed }
    }

    static func version(_ wine: WineBinary) async -> String? {
        await Task.detached {
            let p = process(wine, ["--version"])
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }.value
    }

    /// Ends every Windows program running in this engine's environment.
    static func killAll(_ wine: WineBinary) {
        let p = Process()
        p.executableURL = wine.wineserver
        p.arguments = ["-k"]
        p.environment = environment(for: wine)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// "/Users/me/Game.exe" -> "Z:\Users\me\Game.exe" (Wine maps Z: to /).
    static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }
}

enum Shell {
    static func wait(for process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    @discardableResult
    static func run(_ tool: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> Int32 {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return try await wait(for: p)
    }
}

/// Splits a launch-options string like `-windowed "save dir"` into arguments.
func splitArguments(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var pending = false
    for c in text {
        if let q = quote {
            if c == q { quote = nil } else { current.append(c) }
        } else if c == "\"" || c == "'" {
            quote = c
            pending = true
        } else if c.isWhitespace {
            if pending || !current.isEmpty { result.append(current) }
            current = ""
            pending = false
        } else {
            current.append(c)
        }
    }
    if pending || !current.isEmpty { result.append(current) }
    return result
}

// MARK: - Downloading engines

/// Downloads an engine into Decanter's own folder.
/// - Wine Staging: Gcenx's macOS builds (the same ones the now-disabled Homebrew casks used).
/// - CrossOver 24: the Sikarugir project's engine, plus the support libraries from its
///   wrapper template, which the engine expects to find beside it.
final class WineInstaller: NSObject, URLSessionDownloadDelegate {
    enum Step {
        case locating
        case downloading(part: Int, parts: Int, received: Int64, total: Int64)
        case unpacking
    }

    private struct Archive {
        let url: URL
        /// Extract only entries matching this pattern, dropping this many leading path parts.
        var only: (pattern: String, stripComponents: Int)?
    }

    private static let stagingAPI = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!
    private static let stagingFallback = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!
    // Pinned: this pair was tested together (a 32-bit GameMaker 8 game runs with sound).
    private static let crossoverEngine = URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!
    private static let crossoverTemplate = URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.19.tar.xz")!

    private var onStep: ((Step) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReported: Int64 = 0
    private var part = 1
    private var parts = 1
    private var name = ""

    func install(_ engine: Engine, onStep: @escaping (Step) -> Void) async throws -> WineBinary {
        self.onStep = onStep
        name = engine.rawValue
        onStep(.locating)
        let archives: [Archive]
        switch engine {
        case .wine:
            archives = [Archive(url: await Self.latestStagingURL() ?? Self.stagingFallback)]
        case .crossover:
            archives = [
                Archive(url: Self.crossoverEngine),
                Archive(url: Self.crossoverTemplate, only: ("*/Contents/Frameworks/*", 3)),
            ]
        }

        let fm = FileManager.default
        let staging = AppPaths.support.appendingPathComponent("\(engine.rawValue).partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        parts = archives.count
        for (i, archive) in archives.enumerated() {
            part = i + 1
            lastReported = 0
            let file = try await download(archive.url)
            onStep(.unpacking)
            try await Self.unpack(file, into: staging, only: archive.only)
        }

        try await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staging.path])
        try fm.createDirectory(at: engine.installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: engine.installDir)
        try fm.moveItem(at: staging, to: engine.installDir)

        guard let wine = WineLocator.find(engine, customPath: "") else { throw WineError.notFound }
        return wine
    }

    private static func latestStagingURL() async -> URL? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let assets: [Asset]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: stagingAPI),
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return release.assets.first {
            $0.name.hasPrefix("wine-staging-") && $0.name.hasSuffix("-osx64.tar.xz")
        }?.browser_download_url
    }

    private static func unpack(_ archive: URL, into folder: URL, only: (pattern: String, stripComponents: Int)?) async throws {
        defer { try? FileManager.default.removeItem(at: archive) }
        var args = ["-xJf", archive.path, "-C", folder.path]
        if let only {
            args += ["--strip-components", String(only.stripComponents), "--include", only.pattern]
        }
        let status = try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), args)
        guard status == 0 else { throw WineError.unpackFailed }
    }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Report roughly every megabyte rather than every packet.
        guard totalBytesWritten - lastReported > 1_000_000 || totalBytesWritten == totalBytesExpectedToWrite else { return }
        lastReported = totalBytesWritten
        onStep?(.downloading(part: part, parts: parts, received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(WineError.downloadFailed(http.statusCode)))
            return
        }
        // The temporary file is deleted when this method returns, so move it now.
        let dest = AppPaths.support.appendingPathComponent("download-\(name)-\(part).tar.xz")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }
}
