import Foundation

/// The Wine engine and graphics a game runs with.
struct Setup: Equatable {
    var engine: Engine
    var graphics: Graphics

    var title: String {
        engine == .crossover ? "\(engine.title) and \(graphics.title)" : engine.title
    }

    /// What Decanter tries for a game, best first. An automatic game starts with the first
    /// and moves down the list each time it closes or crashes as it starts. Wine Staging is
    /// only on the list when it's already installed, so a retry never starts a big download.
    static func candidates(for exe: URL, madeWith maker: Maker?, stagingInstalled: Bool) -> [Setup] {
        // A game installed with Run Installer has to stay in the engine it was installed in.
        if let engine = Engine.owning(exe.path) {
            return engine == .crossover
                ? [Setup(engine: .crossover, graphics: .opengl), Setup(engine: .crossover, graphics: .dxvk)]
                : [Setup(engine: .wine, graphics: .opengl)]
        }
        // Unity 6 and Unreal Engine draw with compute shaders, which need Direct3D feature
        // level 11. Only DXVK has that. OpenGL stops at 10.1.
        let graphics: [Graphics] = maker?.needsFeatureLevel11 == true ? [.dxvk, .opengl] : [.opengl, .dxvk]
        let crossover = graphics.map { Setup(engine: .crossover, graphics: $0) }
        // Wine Staging goes last, and never for Unity or Unreal games, because on Apple Silicon
        // it can't run Direct3D 10/11 games at all.
        return stagingInstalled && !(maker?.usesDirect3D11 ?? false) ? crossover + [Setup(engine: .wine, graphics: .opengl)] : crossover
    }

    /// Games made to run inside Microsoft Edge WebView2, like Construct 3's default Windows
    /// export. The WebView2 installer crashes in Wine, so no setup can run them.
    static func usesWebView2(_ exe: URL) -> Bool {
        FileManager.default.fileExists(atPath: exe.deletingLastPathComponent().appendingPathComponent("WebView2Loader.dll").path)
    }
}

/// What a game was made with, worked out from the files beside its .exe before it starts.
/// Decanter uses it to pick the best setup and to open the game full screen or in a window.
enum Maker: Equatable {
    case unity(version: String?)
    case unreal
    case godot
    case gameMaker
    case rpgMaker
    case renpy
    case monoGame
    case fna
    case love

    static func of(_ exe: URL) -> Maker? {
        let fm = FileManager.default
        let folder = exe.deletingLastPathComponent()
        let base = exe.deletingPathExtension().lastPathComponent
        func has(_ path: String) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent(path).path) }

        if has(base + "_Data") || has("UnityPlayer.dll") { return .unity(version: unityVersion(of: exe)) }
        // Unreal games start from a small .exe beside an Engine folder, which in turn starts
        // <Game>/Binaries/Win64/<Game>-Win64-Shipping.exe.
        if has("Engine/Binaries") || has(base + "/Binaries/Win64")
            || (base.hasSuffix("-Shipping") && folder.path.contains("/Binaries/Win")) {
            return .unreal
        }
        if has(base + ".pck") || endsWithGodotPack(exe) { return .godot }
        if has("data.win") { return .gameMaker }
        if has("www/js/rpg_core.js") || has("js/rmmz_core.js") || has("Game.rgss3a") || has("Game.rgss2a")
            || has("Game.rgssad") || has("System/RGSS301.dll") || has("System/RGSS300.dll") {
            return .rpgMaker
        }
        if has("renpy") && has("game") { return .renpy }
        if has("MonoGame.Framework.dll") { return .monoGame }
        if has("FNA.dll") { return .fna }
        if has("love.dll") { return .love }
        return nil
    }

    var title: String {
        switch self {
        case .unity(let version):
            // "2021.3.11f1" means Unity 2021.3, and "6000.0.23f1" means Unity 6.
            guard let parts = version?.split(separator: "."), parts.count > 1 else { return "Unity" }
            return (Int(parts[0]) ?? 0) >= 6000 ? "Unity 6" : "Unity \(parts[0]).\(parts[1])"
        case .unreal: return "Unreal Engine"
        case .godot: return "Godot"
        case .gameMaker: return "GameMaker"
        case .rpgMaker: return "RPG Maker"
        case .renpy: return "Ren’Py"
        case .monoGame: return "MonoGame"
        case .fna: return "FNA"
        case .love: return "LÖVE"
        }
    }

    var usesDirect3D11: Bool {
        switch self {
        case .unity, .unreal: return true
        default: return false
        }
    }

    var needsFeatureLevel11: Bool {
        switch self {
        case .unity(let version): return version.flatMap { Int($0.prefix(while: \.isNumber)) }.map { $0 >= 6000 } ?? false
        case .unreal: return true
        default: return false
        }
    }

    /// Arguments the game always starts with. Unreal Engine 5 prefers Direct3D 12, which
    /// Wine can't run on a Mac, so Unreal games are asked for Direct3D 11.
    var launchArguments: [String] {
        self == .unreal ? ["-dx11"] : []
    }

    /// The switches that open the game full screen or in a 1280 × 720 window, for engines that
    /// have them. It's nil for games that decide for themselves.
    func arguments(for display: Display) -> [String]? {
        switch (self, display) {
        case (_, .gameSetting): return []
        case (.unity, .fullScreen): return ["-screen-fullscreen", "1"]
        case (.unity, .windowed): return ["-screen-fullscreen", "0", "-screen-width", "1280", "-screen-height", "720"]
        case (.godot, .fullScreen): return ["--fullscreen"]
        case (.godot, .windowed): return ["--windowed", "--resolution", "1280x720"]
        case (.unreal, .fullScreen): return ["-fullscreen"]
        case (.unreal, .windowed): return ["-windowed", "-ResX=1280", "-ResY=720"]
        default: return nil
        }
    }

    var canSetDisplay: Bool { arguments(for: .windowed) != nil }

    /// The Unity version a game was made with, like "2021.3.11f1", read from the start of
    /// the files in its _Data folder.
    static func unityVersion(of exe: URL) -> String? {
        let data = exe.deletingLastPathComponent()
            .appendingPathComponent(exe.deletingPathExtension().lastPathComponent + "_Data")
        for file in ["globalgamemanagers", "mainData", "data.unity3d"] {
            guard let handle = FileHandle(forReadingAtPath: data.appendingPathComponent(file).path) else { continue }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            if let match = head.range(of: #"(20\d\d|6\d\d\d|5)\.\d+\.\d+[abfp]\d+"#, options: .regularExpression) {
                return String(head[match])
            }
        }
        return nil
    }

    /// Godot can pack a game's files into its .exe, which then ends with "GDPC".
    private static func endsWithGodotPack(_ exe: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 4 else { return false }
        try? handle.seek(toOffset: end - 4)
        return (try? handle.read(upToCount: 4)) == Data("GDPC".utf8)
    }
}

/// How a game opens: however it likes, full screen, or in a window.
enum Display: String, Codable, CaseIterable, Identifiable {
    case gameSetting, fullScreen, windowed

    var id: Self { self }

    var title: String {
        switch self {
        case .gameSetting: "Game’s Setting"
        case .fullScreen: "Full Screen"
        case .windowed: "Windowed"
        }
    }
}
