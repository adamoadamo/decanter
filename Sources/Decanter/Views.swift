import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if model.needsSetup {
                WineSetupView()
            } else if let id = model.selection, model.game(id) != nil {
                GameDetailView(gameID: id).id(id)
            } else {
                EmptyLibraryView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.showAddPanel() } label: { Label("Add Game", systemImage: "plus") }
                    .help("Add a Windows game (.exe)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            "“\(model.pendingInstaller?.lastPathComponent ?? "")” looks like an installer",
            isPresented: Binding(get: { model.pendingInstaller != nil }, set: { if !$0 { model.pendingInstaller = nil } })
        ) {
            if let url = model.pendingInstaller {
                Button("Run Installer") { model.runInstaller(url) }
                Button("Add to Library Instead") { model.addToLibrary(url) }
            }
        } message: {
            Text("Run it to install the game into Decanter’s Windows environment. You’ll pick the installed game afterwards.")
        }
        .confirmationDialog(
            "Remove “\(model.pendingRemoval?.name ?? "")” from the library?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { game in
            Button("Remove", role: .destructive) { model.remove(game) }
        } message: { _ in
            Text("The game’s files aren’t deleted.")
        }
        .sheet(item: $model.renaming) { game in
            RenameSheet(game: game)
        }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {}
        .alert("Decanter \(model.update?.version ?? "") is available",
               isPresented: Binding(get: { model.update != nil }, set: { if !$0 { model.update = nil } }),
               presenting: model.update) { release in
            Button("Install and Relaunch") { model.installUpdate(release) }
            Button("Skip This Version") { model.skip(release) }
            Button("Later", role: .cancel) {}
        } message: { release in
            Text("You have \(Updates.currentVersion). Decanter restarts to finish, and closes any games that are running.\n\n\(release.body.map { String($0.prefix(500)) } ?? "")")
        }
        .overlay(alignment: .bottom) {
            if case let .installing(release) = model.updateStatus {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Updating to Decanter \(release.version)…")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding()
            } else if model.installerRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Installer running… finish it in its own window.")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding()
            }
        }
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @FocusState private var focused: Bool

    private var shownGames: [Game] {
        search.isEmpty ? model.sortedGames : model.sortedGames.filter { $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Games") {
                ForEach(shownGames) { game in
                    GameRow(game: game).tag(game.id)
                }
            }
        }
        // The window opens with the game list focused, so arrow keys pick a game.
        .focused($focused)
        .defaultFocus($focused, true)
        .searchable(text: $search, placement: .sidebar, prompt: "Search Games")
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            if let game = ids.first.flatMap(model.game) {
                GameMenuItems(game: game)
            } else {
                Button("Add Game…") { model.showAddPanel() }
            }
        } primaryAction: { ids in
            // This runs on a double-click or when Return is pressed.
            if let game = ids.first.flatMap(model.game), model.running[game.id] == nil { model.play(game) }
        }
        .onDeleteCommand {
            if let game = model.game(model.selection) { model.requestRemoval(of: game) }
        }
        .overlay {
            if model.games.isEmpty {
                Text("Drop .exe files here").foregroundStyle(.secondary)
            } else if shownGames.isEmpty {
                Text("No Games Found").foregroundStyle(.secondary)
            }
        }
    }
}

/// A game's right-click menu.
struct GameMenuItems: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if model.running[game.id] != nil || model.starting.contains(game.id) {
            Button("Stop") { model.stop(game) }
        } else {
            Button("Play") { model.play(game) }.disabled(model.needsSetup)
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
        Button("Rename…") { model.renaming = game }
        Divider()
        Button("Remove from Library…") { model.requestRemoval(of: game) }
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        HStack(spacing: 10) {
            GameIcon(game: game, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).lineLimit(1)
                if model.running[game.id] != nil {
                    Text("Playing").font(.caption).foregroundStyle(.green)
                } else if model.starting.contains(game.id) {
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct GameIcon: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let size: CGFloat

    var body: some View {
        if let image = model.icon(for: game) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(.white)
                }
        }
    }
}

// MARK: - Game detail

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let gameID: UUID
    @State private var showLog = false

    var body: some View {
        if let game = model.game(gameID), let binding = model.binding(for: gameID) {
            let log = model.logs[gameID] ?? ""
            Form {
                Section {
                    HStack(spacing: 18) {
                        GameIcon(game: game, size: 80)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(game.name)
                                .font(.title.bold())
                            Group {
                                let maker = model.maker(of: game)
                                switch (maker, game.lastPlayed) {
                                case let (maker?, date?):
                                    Text("Made with \(maker.title) · Last played \(date, format: .relative(presentation: .named))")
                                case let (maker?, nil):
                                    Text("Made with \(maker.title)")
                                case let (nil, date?):
                                    Text("Last played \(date, format: .relative(presentation: .named))")
                                case (nil, nil):
                                    EmptyView()
                                }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)

                    HStack(spacing: 10) {
                        playButton(game)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([game.url])
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .labelStyle(.iconOnly)
                        }
                        .controlSize(.extraLarge)
                        .help("Show in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: game.exePath))
                        Spacer()
                    }
                    if !FileManager.default.fileExists(atPath: game.exePath) {
                        HStack {
                            Label("Can’t find the game file. Was it moved or deleted?", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Locate…") { model.locate(game) }
                        }
                    }
                    if model.starting.contains(gameID), case let .working(message, fraction) = model.installState(game.engine) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let notice = model.notices[gameID] {
                        Label(notice, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Options") {
                    let busy = model.running[gameID] != nil || model.starting.contains(gameID)
                    // When on, Decanter picks the engine and graphics, and tries another setup if the game closes as it starts.
                    Toggle("Choose automatically", isOn: Binding(get: { game.automatic }, set: { model.setAutomatic($0, for: gameID) }))
                    .disabled(busy)
                    // Picking either by hand turns automatic off.
                    Picker(selection: Binding(get: { game.engine }, set: {
                        binding.wrappedValue.engine = $0
                        binding.wrappedValue.automatic = false
                    })) {
                        ForEach(Engine.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Text("Wine engine")
                    }
                    // A game installed with Run Installer stays in the engine it was installed in.
                    .disabled(busy || Engine.owning(game.exePath) != nil)
                    if game.engine == .crossover {
                        Picker(selection: Binding(get: { game.graphics }, set: {
                            binding.wrappedValue.graphics = $0
                            binding.wrappedValue.automatic = false
                        })) {
                            ForEach(Graphics.allCases) { Text($0.title).tag($0) }
                        } label: {
                            Text("Graphics")  // This only affects Direct3D 10 and 11.
                        }
                        .disabled(busy)
                    }
                    // Only some engines can be told how to open. The rest decide for themselves.
                    let settable = model.maker(of: game)?.canSetDisplay ?? false
                    Picker("Display", selection: Binding(get: { settable ? game.display : .gameSetting },
                                                         set: { binding.wrappedValue.display = $0 })) {
                        ForEach(Display.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!settable)
                    .help(settable ? "Takes effect the next time the game starts."
                                   : "This game decides for itself. Look for the option in its own settings.")
                }

                Section {
                    DisclosureGroup(isExpanded: $showLog) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(log.isEmpty ? "Nothing yet. Wine’s output appears here when you play." : String(log.suffix(20_000)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(log.isEmpty ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("end")
                            }
                            .frame(height: 200)
                            .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
                            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    } label: {
                        HStack {
                            Text("Log")
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(log, forType: .string)
                            }
                            .disabled(log.isEmpty)
                        }
                    }
                }

                Section {
                    Button("Remove from Library…", role: .destructive) { model.requestRemoval(of: game) }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func playButton(_ game: Game) -> some View {
        if model.running[game.id] != nil {
            Button { model.stop(game) } label: {
                Label("Stop", systemImage: "stop.fill").frame(minWidth: 110)
            }
            .controlSize(.extraLarge)
        } else if model.starting.contains(game.id) {
            HStack(spacing: 10) {
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    }
                    .frame(minWidth: 110)
                }
                .controlSize(.extraLarge)
                .disabled(true)
                Button("Cancel") { model.stop(game) }
                    .controlSize(.large)
            }
        } else {
            Button { model.play(game) } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(!FileManager.default.fileExists(atPath: game.exePath))
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Games Yet", systemImage: "gamecontroller")
        } description: {
            Text("Drag a Windows game’s .exe file here, or add one from Finder.\nGot an installer (setup.exe)? Decanter will run it for you.")
        } actions: {
            Button("Add Game…") { model.showAddPanel() }
                .buttonStyle(.borderedProminent)
            Button("Run Installer…") { model.showInstallerPanel() }
        }
    }
}

// MARK: - First-run setup

struct WineSetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("One-Time Setup").font(.title.bold())
            Text("Decanter runs Windows games with **Wine**, a free compatibility layer, using the \(Engine.default.title) engine. It’s \(Engine.default.downloadSize) to download and stays inside Decanter’s own folder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if model.rosettaMissing {
                VStack(spacing: 10) {
                    Text("Wine needs Apple’s **Rosetta 2** first.")
                    HStack {
                        Button("Install Rosetta…") { model.installRosetta() }
                            .buttonStyle(.borderedProminent)
                        Button("Check Again") { model.refreshEngines() }
                    }
                }
            } else {
                switch model.installState(.default) {
                case .idle:
                    Button("Download Wine") { model.setUpFirstRun() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                case let .working(message, fraction):
                    VStack(spacing: 8) {
                        if let fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(width: 320)
                case let .failed(message):
                    VStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Try Again") { model.setUpFirstRun() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

        }
        .frame(maxWidth: 440)
        .padding(40)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset: Engine?

    var body: some View {
        Form {
            ForEach(Engine.allCases) { engine in
                EngineSettings(engine: engine, confirmReset: $confirmReset)
            }
            Section {
                Button("Force Quit All Windows Programs") { model.stopAll() }
                if model.rosettaMissing {
                    Button("Install Rosetta 2…") { model.installRosetta() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            "Reset \(confirmReset?.title ?? "")’s Windows environment?",
            isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
            presenting: confirmReset
        ) { engine in
            Button("Reset", role: .destructive) { model.resetPrefix(engine) }
        } message: { engine in
            Text("This deletes everything installed with Run Installer in \(engine.title), plus any saves or settings games stored there. Your library and games added from elsewhere aren’t touched.")
        }
    }
}

private struct EngineSettings: View {
    @Environment(AppModel.self) private var model
    let engine: Engine
    @Binding var confirmReset: Engine?

    var body: some View {
        let wine = model.engines[engine]
        let state = model.installState(engine)
        Section {
            LabeledContent("Version", value: model.versions[engine] ?? (wine == nil ? "Not installed" : "…"))
            if let wine {
                LabeledContent("Location") {
                    Text((wine.wine.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            switch state {
            case let .working(message, fraction):
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
            HStack {
                if engine == .wine {
                    Button("Choose Wine…") { model.chooseWine() }
                    Button("Use Automatic") { model.useAutomaticWine() }
                        .disabled(model.customWinePath.isEmpty)
                }
                Spacer()
                Button(wine == nil ? "Download (\(engine.downloadSize))" : engine == .wine ? "Download Latest" : "Reinstall") {
                    model.download(engine)
                }
                .disabled(state.isWorking || model.isInUse(engine))
            }
            HStack {
                Button("Wine Configuration…") { model.openWineTool("winecfg", engine: engine) }
                Button("Show C: Drive") { model.showDriveC(engine) }
                Spacer()
                Button("Reset…", role: .destructive) { confirmReset = engine }
            }
            .disabled(wine == nil || state.isWorking)
        } header: {
            Text(engine == .default ? "\(engine.title) (default)" : engine.title)
        } footer: {
            Text(engine.summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var name: String

    init(game: Game) {
        self.game = game
        _name = State(initialValue: game.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(game.name)”").font(.headline)
            TextField("Name", text: $name)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(game.id, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 340)
        .padding(20)
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Decanter").font(.title.bold())
            Text("Version \(Updates.currentVersion) (\(Updates.build))")
                .foregroundStyle(.secondary)
            status
                .font(.callout)
                .frame(minHeight: 22)
            if case let .available(release) = model.updateStatus {
                Button("Install Decanter \(release.version)") { model.installUpdate(release) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Check for Updates") { model.checkForUpdates(userInitiated: true, answerInAbout: true) }
                    .disabled(model.updateStatus == .checking || model.updateStatus.isInstalling)
            }
        }
        .padding(28)
        .frame(width: 320)
    }

    @ViewBuilder private var status: some View {
        switch model.updateStatus {
        case .unknown:
            Color.clear.frame(height: 1)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Text("You have the latest version.").foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t check for updates.").foregroundStyle(.secondary)
        case let .available(release):
            Text("Decanter \(release.version) is out.")
        case let .installing(release):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating to Decanter \(release.version)…").foregroundStyle(.secondary)
            }
        }
    }
}
