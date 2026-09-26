import Foundation

/// The Wine engine and graphics a game runs with.
struct Setup: Equatable {
    var engine: Engine
    var graphics: Graphics

    var title: String {
        engine == .crossover ? "\(engine.title) and \(graphics.title)" : engine.title
    }

    /// What Decanter tries for a game, best first. An automatic game starts with the first
    /// and moves down the list each time it closes or crashes as it starts.
    static func candidates(for exe: URL) -> [Setup] {
        // A game installed with Run Installer has to stay in the engine it was installed in.
        if let engine = Engine.owning(exe.path) {
            return engine == .crossover
                ? [Setup(engine: .crossover, graphics: .opengl), Setup(engine: .crossover, graphics: .dxvk)]
                : [Setup(engine: .wine, graphics: .opengl)]
        }
        // Unity 6 draws with compute shaders, which need Direct3D feature level 11. Only DXVK
        // has it; OpenGL stops at 10.1.
        let unity6 = unityVersion(of: exe).flatMap { Int($0.prefix(while: \.isNumber)) }.map { $0 >= 6000 } ?? false
        let graphics: [Graphics] = unity6 ? [.dxvk, .opengl] : [.opengl, .dxvk]
        // Wine Staging last: on Apple Silicon it can't run Direct3D 10/11 games at all.
        return graphics.map { Setup(engine: .crossover, graphics: $0) } + [Setup(engine: .wine, graphics: .opengl)]
    }

    /// The Unity version a game was made with, like "2021.3.11f1", read from the start of
    /// the files in its _Data folder. Nil for games not made with Unity.
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
}
