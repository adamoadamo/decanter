# Decanter

A small Mac app for playing simple Windows indie games. Drop in a game's `.exe` and press Play. It runs the game with [Wine](https://www.winehq.org), which Decanter downloads and manages itself.

Decanter was called Yeobgamer up to version 1.1. Updating moves its library, engines and saves across automatically.

## Using it

1. **First launch:** click **Download Wine** (about 260 MB, one time). On Apple Silicon, Wine also needs Rosetta 2, and the app offers to install it if it's missing.
2. **Add a game:** drag its `.exe` onto the window, press **+**, or right-click the `.exe` in Finder → Open With → Decanter.
3. **Installers:** if you add a `setup.exe` or `.msi`, Decanter runs it and then asks which installed `.exe` to add.
4. **Play.** The first launch spends about a minute setting up the Windows environment.
5. **Quit:** press **⌘Q** while playing to quit the game. ⌘Q in Decanter quits Decanter and any running games. Game → Stop (⌘.) stops the selected game.

Per-game options:

- **Wine engine:** see below.
- **Run inside a window:** a Wine virtual desktop, for games that change the screen resolution.
- **Launch options:** command-line arguments to pass to the game.
- **Log:** Wine's output while the game runs.

If a game ships runtime installers next to its `.exe` (`oalinst.exe` for OpenAL, `vcredist*.exe` for Visual C++), Decanter installs them silently the first time you press Play.

**Settings (⌘,)** has Wine configuration, the C: drive in Finder, force quit, reset, and a way to pick a different Wine.

## Engines

Each game runs with one of two Wine builds. Pick one per game under Options. Each engine has its own Windows environment, so installing something in one doesn't affect the other.

- **CrossOver 24** (default): CodeWeavers' CrossOver Wine, built by the [Sikarugir](https://github.com/Sikarugir-App) project, plus the support libraries (fonts, sound, controllers) from Sikarugir's wrapper template. Best for older 32-bit games on Apple Silicon.
- **Wine Staging**: the newest upstream Wine ([Gcenx's builds](https://github.com/Gcenx/macOS_Wine_builds)). It downloads the first time a game that uses it is played.

If a game crashes inside Wine, Decanter stops it and suggests trying the other engine.

## What works

Simple 2D and older DirectX 8/9 games, Unity, GameMaker, and RPG Maker games usually have the best chance. Anti-cheat, DRM-heavy, and demanding DirectX 11/12 games generally won't run.

LISA (GameMaker 8, 32-bit) is an example of why there are two engines. On Apple Silicon it crashes at startup under every upstream Wine 11 build tried (Staging and Devel 11.18, Stable 11.0), inside Wine's 32-to-64-bit layer under Rosetta. On CrossOver 24 it runs with graphics and sound.

## Where things live

`~/Library/Application Support/Decanter/`:

- `Engines/CrossOver/`: the CrossOver 24 engine and its support libraries
- `Prefix-CrossOver/`: CrossOver's Windows environment, including the C: drive and any saves games put there
- `Wine/` and `Prefix/`: the same for Wine Staging
- `Icons/`: icons pulled from each game's `.exe`
- `library.json`: your game list

## Building

Needs the Xcode Command Line Tools (Swift 5.9+) on macOS 14 or later.

```
./build.sh              # quick ad-hoc build → build/Decanter.app
./build.sh --notarise   # Developer ID signed + notarised → dist/  (see RELEASING.md)
```

Code is in `Sources/Decanter/`:

- `Wine.swift`: finding, downloading and running Wine
- `AppModel.swift`: the library, launching, installers
- `PEIcon.swift`: reads icons out of `.exe` files
- `Views.swift`: the SwiftUI interface
- `Updates.swift`: checks GitHub releases for a newer version
