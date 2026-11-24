import AppKit

enum EngineState: Equatable {
    case active(String)
    case idle
    case working
    case needsPermission
}

/// Una finestra aperta, su qualsiasi scrivania.
struct TrackedWindow {
    let windowID: CGWindowID?
    let pid: pid_t
    let bundleID: String
    let appName: String
    var title: String
    var frame: CGRect
    /// Elemento di Accessibilità: c'è se macOS lo espone (di solito per le scrivanie visibili).
    var live: LiveWindow?
    var displayKey: String
    /// Scrivania del monitor (da 1). Nil se è su tutte le scrivanie o non si sa.
    var desktop: Int?
    var chromeProfile: String?
    var isMinimized: Bool
    var isFullScreen: Bool
    /// Documento della finestra: per il Finder l'indirizzo della cartella mostrata.
    var document: String? = nil
    /// Schede aperte (Chrome), dai file di sessione.
    var tabs: [String]? = nil
}

/// Una finestra salvata abbinata alla finestra aperta che la rappresenta.
struct Assignment {
    let saved: SavedWindow
    var tracked: TrackedWindow
    /// La finestra è stata spostata o ha cambiato stato: va riposizionata.
    var needsFrame = false
}

/// Salva e richiama le scene.
@MainActor
final class Engine {
    let store: SceneStore
    var onStateChange: (@MainActor () -> Void)?
    /// Avvisa l'interfaccia di cosa sta facendo e di cosa ha fatto (richiamo e salvataggio).
    var onActivity: (@MainActor (ActivityReport) -> Void)?
    /// Chiede all'utente il profilo delle finestre di Chrome che Ormeggio non riconosce da solo.
    var askChromeProfiles: (@MainActor (_ titles: [String], _ profiles: [ChromeProfile]) -> [String?])?

    private(set) var state: EngineState = .idle {
        didSet { if state != oldValue { onStateChange?() } }
    }

    private var lastFingerprint: String?
    private var isBusy = false
    private var pendingCheck: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    static let settingsID = "com.apple.systempreferences"

    init(store: SceneStore) {
        self.store = store
    }

    // MARK: Impostazioni

    /// Richiama da sola la scena automatica quando cambiano i monitor.
    var autoApplyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "autoApply") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoApply") }
    }

    /// Riduce nel Dock le finestre che non fanno parte della scena, sulle scrivanie della scena.
    var minimizeOthers: Bool {
        get { UserDefaults.standard.object(forKey: "minimizeOthers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "minimizeOthers") }
    }

    /// Gestisce le scrivanie (le crea, le toglie, ci sposta le finestre).
    var manageSpaces: Bool {
        get { UserDefaults.standard.object(forKey: "manageSpaces") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "manageSpaces") }
    }

    var activeSceneID: UUID? {
        get { UserDefaults.standard.string(forKey: "activeScene").flatMap { UUID(uuidString: $0) } }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "activeScene") }
    }

    var activeScene: SavedScene? {
        activeSceneID.flatMap { store.scene(id: $0) }
    }

    var isWorking: Bool { isBusy }

    // MARK: Avvio e osservazione

    func start() {
        for app in WindowManager.regularApps() {
            WindowManager.disableFullAccessibility(pid: app.processIdentifier)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleCheck(reason: "monitor cambiati") }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scheduleCheck(reason: "risveglio", delay: 4) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self.appLaunched(bundleID) }
        })
        refreshState()
        scheduleCheck(reason: "avvio", delay: 5)
    }

    func refreshState() {
        if !WindowManager.isTrusted(prompt: false) {
            state = .needsPermission
        } else if isBusy {
            state = .working
        } else if let scene = activeScene {
            state = .active(scene.name)
        } else {
            state = .idle
        }
    }

    private func scheduleCheck(reason: String, delay: Double = 3) {
        pendingCheck?.cancel()
        pendingCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.autoCheck(reason: reason)
        }
    }

    private func autoCheck(reason: String) async {
        let fingerprint = DisplayManager.fingerprint(DisplayManager.activeDisplays())
        // All'avvio (anche dopo un aggiornamento) prendo solo nota dei monitor: non sposto niente.
        guard let previous = lastFingerprint else {
            lastFingerprint = fingerprint
            if activeSceneID == nil, let scene = store.autoScene(for: fingerprint) { activeSceneID = scene.id }
            refreshState()
            return
        }
        guard fingerprint != previous, !isBusy else {
            refreshState()
            return
        }
        if let active = activeScene, active.fingerprint != fingerprint {
            activeSceneID = nil
        }
        refreshState()
        guard autoApplyEnabled, store.autoScene(for: fingerprint) != nil else {
            lastFingerprint = fingerprint
            Log.write("Monitor cambiati (\(reason)): nessuna scena automatica per questi monitor")
            return
        }
        onActivity?(ActivityReport(
            kind: .working,
            title: "Monitor collegati: aspetto che macOS finisca",
            subtitle: "Poi rimetto tutto come nella scena"
        ))
        // Se arrivano altri cambiamenti, questo controllo viene annullato e ne parte uno nuovo.
        guard await waitForStableDisplays(), !Task.isCancelled else { return }
        let settled = DisplayManager.fingerprint(DisplayManager.activeDisplays())
        lastFingerprint = settled
        guard let scene = store.autoScene(for: settled) else {
            Log.write("Monitor cambiati (\(reason)): a monitor fermi nessuna scena automatica")
            onActivity?(ActivityReport(kind: .success, title: "Nessuna scena per questi monitor", subtitle: nil))
            return
        }
        Log.write("Richiamo automatico di \"\(scene.name)\" (\(reason))")
        await apply(scene)
    }

    /// Dopo un cambio di monitor macOS impiega diversi secondi a rimettere le scrivanie sul monitor giusto.
    /// Aspetto che monitor e numero di scrivanie restino uguali per 4 secondi di fila, al massimo 40 secondi.
    /// Restituisce false se nel frattempo il controllo è stato annullato.
    private func waitForStableDisplays() async -> Bool {
        var last = ""
        var stableSince = Date()
        let started = Date()
        while Date().timeIntervalSince(started) < 40 {
            if Task.isCancelled { return false }
            let displays = DisplayManager.activeDisplays()
            let layouts = SpacesManager.layouts(for: displays)
            let counts = displays.map { "\($0.key):\(layouts[$0.id]?.count ?? -1)" }.joined(separator: ",")
            let snapshot = DisplayManager.fingerprint(displays) + "|" + counts
            if snapshot != last {
                last = snapshot
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 4 {
                Log.write("Monitor fermi dopo \(Int(Date().timeIntervalSince(started))) secondi: \(counts)")
                return true
            }
            await Input.pause(1)
        }
        Log.write("Monitor ancora in movimento dopo 40 secondi: procedo")
        return !Task.isCancelled
    }

    /// Quando si apre un'app, mette le sue finestre dove le vuole la scena attiva.
    private func appLaunched(_ bundleID: String?) {
        guard let bundleID, autoApplyEnabled, !isBusy, let scene = activeScene,
              scene.windows.contains(where: { $0.bundleID == bundleID }) else { return }
        Task { @MainActor in
            await Input.pause(2)
            guard !self.isBusy else { return }
            await self.placeLaunchedApp(bundleID, scene: scene)
        }
    }

    private func placeLaunchedApp(_ bundleID: String, scene: SavedScene) async {
        let displays = DisplayManager.activeDisplays()
        let tracked = inventory(displays: displays, profiles: []).filter { $0.bundleID == bundleID }
        let result = match(scene.windows.filter { $0.bundleID == bundleID }, with: tracked)
        guard !result.assignments.isEmpty else { return }
        isBusy = true
        refreshState()
        var assignments = result.assignments
        await relocate(&assignments, scene: scene, displays: displays)
        await placeFrames(&assignments, scene: scene, displays: displays)
        isBusy = false
        refreshState()
    }

    // MARK: Salvataggio

    func saveScene(name: String, autoApply: Bool) async {
        guard !isBusy else { return }
        guard WindowManager.isTrusted(prompt: false) else {
            refreshState()
            return
        }
        isBusy = true
        refreshState()
        var scene = capture(name: name)
        scene.autoApply = autoApply
        store.save(scene)
        let savedID = store.scene(named: name)?.id
        activeSceneID = savedID
        lastFingerprint = scene.fingerprint
        isBusy = false
        refreshState()
        reportSaved(scene)
        if let savedID, scene.windows.contains(where: { $0.bundleID == BrowserBridge.chromeID }) {
            scheduleChromeZoomRefresh(id: savedID)
        }
        Log.write("Scena \"\(name)\" salvata: \(scene.windows.count) finestre, \(scene.apps.count) app. "
                  + scene.windows.map { "\($0.appName) [\($0.displayKey) scrivania \($0.desktop.map { "\($0)" } ?? "?")]" }.joined(separator: ", "))
    }

    func deleteScene(id: UUID) {
        if activeSceneID == id { activeSceneID = nil }
        store.delete(id: id)
        refreshState()
    }

    func renameScene(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id: id) { $0.name = trimmed }
        refreshState()
    }

    func setAutoApply(id: UUID, _ enabled: Bool) {
        store.update(id: id) { $0.autoApply = enabled }
    }

    func setIcon(id: UUID, _ icon: String) {
        store.update(id: id) { $0.icon = icon }
    }

    /// Fotografa lo stato del Mac. Legge le finestre di tutte le scrivanie senza spostarsi.
    private func capture(name: String) -> SavedScene {
        let displays = DisplayManager.activeDisplays()
        let layouts = SpacesManager.layouts(for: displays)

        let running = WindowManager.regularApps()
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        // AppleScript solo se macOS ha già dato il permesso: così non compare nessuna domanda.
        func scriptable(_ bundleID: String) -> Bool {
            runningIDs.contains(bundleID) && BrowserBridge.automationCode(bundleID: bundleID, ask: false) == 0
        }
        let finderFolders = scriptable(FinderBridge.bundleID) ? FinderBridge.openFolders() : []
        var chromeInfos = scriptable(BrowserBridge.chromeID) ? BrowserBridge.windows(bundleID: BrowserBridge.chromeID) : []
        var safariInfos = scriptable(BrowserBridge.safariID) ? BrowserBridge.windows(bundleID: BrowserBridge.safariID) : []
        let profiles = runningIDs.contains(BrowserBridge.chromeID) ? BrowserBridge.chromeProfiles() : []
        // Schede, profilo e posizione di ogni finestra di Chrome, dai file di sessione: nessun permesso.
        let chromeSessions = runningIDs.contains(BrowserBridge.chromeID) ? ChromeSession.windows(profiles: profiles) : []
        Log.write("Sessioni di Chrome lette: \(chromeSessions.count) finestre, \(chromeSessions.reduce(0) { $0 + $1.tabs.count }) schede")

        // Profili di Chrome già noti dalle scene salvate, per le finestre ancora aperte.
        var knownProfiles: [CGWindowID: String] = [:]
        for scene in store.scenes {
            for window in scene.windows {
                if let id = window.windowID, let profile = window.chromeProfile { knownProfiles[id] = profile }
            }
        }

        let tracked = inventory(displays: displays, profiles: profiles, knownProfiles: knownProfiles)

        let savedDisplays = displays.map { display in
            DisplayInfo(
                key: display.key,
                name: display.name,
                isBuiltin: display.isBuiltin,
                bounds: CodableRect(display.bounds),
                mode: display.mode,
                spaceCount: layouts[display.id]?.count,
                currentDesktop: layouts[display.id]?.currentIndex.map { $0 + 1 }
            )
        }

        // Ogni finestra di Chrome aperta con la sua finestra della sessione.
        let chromeIndices = tracked.indices.filter { tracked[$0].bundleID == BrowserBridge.chromeID }
        let chromeFound = ChromeSession.assign(
            chromeIndices.map { (title: tracked[$0].title, frame: tracked[$0].frame, profile: tracked[$0].chromeProfile) },
            sessions: chromeSessions
        )
        var sessionFor: [Int: ChromeSessionWindow] = [:]
        for (position, trackedIndex) in chromeIndices.enumerated() {
            if let session = chromeFound[position] { sessionFor[trackedIndex] = session }
        }

        var unusedFolders = finderFolders
        var counters: [String: Int] = [:]
        var windows: [SavedWindow] = []
        for (trackedIndex, item) in tracked.enumerated() {
            guard let display = displays.first(where: { $0.key == item.displayKey }) else { continue }
            let relative = CGRect(
                x: item.frame.minX - display.bounds.minX,
                y: item.frame.minY - display.bounds.minY,
                width: item.frame.width,
                height: item.frame.height
            )
            let index = counters[item.bundleID, default: 0]
            counters[item.bundleID] = index + 1
            var saved = SavedWindow(
                bundleID: item.bundleID,
                appName: item.appName,
                title: item.title,
                index: index,
                displayKey: display.key,
                frame: CodableRect(relative),
                desktop: item.desktop,
                windowID: item.windowID,
                documentURL: item.live?.documentURL,
                chromeProfile: item.chromeProfile,
                minimized: item.isMinimized ? true : nil,
                fullScreen: item.isFullScreen ? true : nil
            )
            switch item.bundleID {
            case FinderBridge.bundleID:
                // La cartella la dice l'Accessibilità; AppleScript resta come riserva.
                if let raw = item.document, let url = URL(string: raw), url.isFileURL {
                    saved.folderPath = url.path
                    if saved.title.isEmpty { saved.title = FinderBridge.displayName(of: url.path) }
                } else if let match = Engine.folderIndex(title: item.title, frame: item.frame, in: unusedFolders) {
                    let folder = unusedFolders.remove(at: match)
                    saved.folderPath = folder.path
                    if saved.title.isEmpty { saved.title = FinderBridge.displayName(of: folder.path) }
                } else if let path = FinderBridge.folder(forTitle: item.title) {
                    saved.folderPath = path
                }
            case BrowserBridge.chromeID:
                if let session = sessionFor[trackedIndex] {
                    saved.tabs = session.tabs
                    if saved.chromeProfile == nil { saved.chromeProfile = session.profile }
                    if saved.title.isEmpty { saved.title = session.activeTitle }
                } else if let match = BrowserBridge.match(title: item.title, frame: item.frame, in: chromeInfos) {
                    let info = chromeInfos.remove(at: match)
                    saved.tabs = info.urls
                    if saved.title.isEmpty { saved.title = info.title }
                }
            case BrowserBridge.safariID:
                if let match = BrowserBridge.match(title: item.title, frame: item.frame, in: safariInfos) {
                    let info = safariInfos.remove(at: match)
                    saved.tabs = info.urls
                    if saved.title.isEmpty { saved.title = info.title }
                }
            default:
                break
            }
            windows.append(saved)
        }

        // Profili di Chrome non riconosciuti: li chiedo all'utente.
        if profiles.count > 1, let ask = askChromeProfiles {
            let unknown = windows.indices.filter {
                windows[$0].bundleID == BrowserBridge.chromeID && windows[$0].chromeProfile == nil
            }
            if !unknown.isEmpty {
                let answers = ask(unknown.map { windows[$0].title }, profiles)
                for (offset, index) in unknown.enumerated() where offset < answers.count {
                    windows[index].chromeProfile = answers[offset]
                }
            }
        }

        let apps = running.compactMap { app -> SavedApp? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return SavedApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        }

        // Zoom di Chrome dei siti aperti, per profilo.
        let chromeZoom = Engine.chromeZoom(for: windows, profiles: profiles)

        return SavedScene(
            id: UUID(),
            name: name,
            fingerprint: DisplayManager.fingerprint(displays),
            autoApply: false,
            displays: savedDisplays,
            apps: apps,
            windows: windows,
            savedAt: Date(),
            chromeZoom: chromeZoom
        )
    }

    // MARK: Dove sono le finestre

    /// Trova le finestre aperte e su quale monitor e scrivania si trovano, senza cambiare scrivania.
    /// Le posizioni vengono dal server delle finestre di macOS; titoli ed elementi di Accessibilità
    /// si aggiungono per le finestre che macOS espone.
    private func inventory(displays: [LiveDisplay], profiles: [ChromeProfile],
                           knownProfiles: [CGWindowID: String] = [:],
                           excluding: Set<CGWindowID> = []) -> [TrackedWindow] {
        let layouts = SpacesManager.layouts(for: displays)
        let userSpaces = Set(layouts.values.flatMap(\.spaceIDs))
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        var liveByID: [CGWindowID: LiveWindow] = [:]
        var liveWithoutID: [LiveWindow] = []
        var exposedIDs = Set<CGWindowID>()
        for app in WindowManager.regularApps() {
            appsByPID[app.processIdentifier] = app
            exposedIDs.formUnion(WindowManager.allWindowIDs(of: app))
            for window in WindowManager.windows(of: app) {
                if let id = window.windowID { liveByID[id] = window } else { liveWithoutID.append(window) }
            }
        }

        var result: [TrackedWindow] = []
        var seen = excluding
        // Titoli delle finestre di Chrome sulle altre scrivanie (servono per profilo e schede).
        var otherDesktopWindows: [pid_t: [CGWindowID: (title: String, document: String?)]] = [:]

        func add(id: CGWindowID?, app: NSRunningApplication, live: LiveWindow?, frame: CGRect, title: String, spaces: [Int], document: String? = nil) {
            guard let bundleID = app.bundleIdentifier,
                  let display = Engine.display(for: frame, in: displays) else { return }
            var desktop: Int?
            if spaces.count == 1, let index = layouts[display.id]?.spaceIDs.firstIndex(of: spaces[0]) {
                desktop = index + 1
            } else if spaces.isEmpty, live?.isMinimized != true {
                desktop = layouts[display.id]?.currentIndex.map { $0 + 1 }
            }
            var profile: String?
            if bundleID == BrowserBridge.chromeID {
                // Il titolo della finestra finisce con il nome del profilo: è l'indizio più affidabile.
                if let fromTitle = BrowserBridge.profile(fromTitle: title, profiles: profiles) {
                    profile = fromTitle
                } else if let id, let known = knownProfiles[id] {
                    profile = known
                } else if let live, !profiles.isEmpty {
                    profile = BrowserBridge.detectProfile(of: live, profiles: profiles)
                }
            }
            result.append(TrackedWindow(
                windowID: id,
                pid: app.processIdentifier,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                title: title,
                frame: frame,
                live: live,
                displayKey: display.key,
                desktop: desktop,
                chromeProfile: profile,
                isMinimized: live?.isMinimized ?? false,
                isFullScreen: live?.isFullScreen ?? false,
                document: live?.documentURL ?? document
            ))
        }

        // 1. Tutte le finestre di tutte le scrivanie, dalla più in primo piano.
        for system in WindowManager.systemWindows() {
            guard !seen.contains(system.id), let app = appsByPID[system.pid] else { continue }
            let spaces = SpacesManager.spaceIDs(forWindow: system.id)
            if let live = liveByID[system.id] {
                seen.insert(system.id)
                add(id: system.id, app: app, live: live, frame: live.frame, title: live.title, spaces: spaces)
            } else {
                // Finestre che l'Accessibilità non mostra, di solito perché sono su un'altra scrivania.
                // Tengo solo quelle normali: su una sola scrivania, visibili e non minuscole.
                guard !exposedIDs.contains(system.id), spaces.count == 1, userSpaces.contains(spaces[0]),
                      system.alpha > 0, system.bounds.width >= 120, system.bounds.height >= 90 else { continue }
                seen.insert(system.id)
                var title = system.name ?? ""
                var document: String?
                if app.bundleIdentifier == BrowserBridge.chromeID || app.bundleIdentifier == FinderBridge.bundleID {
                    if otherDesktopWindows[app.processIdentifier] == nil {
                        otherDesktopWindows[app.processIdentifier] = WindowManager.windowsOnAllDesktops(pid: app.processIdentifier)
                    }
                    let info = otherDesktopWindows[app.processIdentifier]?[system.id]
                    if title.isEmpty { title = info?.title ?? "" }
                    document = info?.document
                }
                add(id: system.id, app: app, live: nil, frame: system.bounds, title: title, spaces: spaces, document: document)
            }
        }

        // 2. Finestre dell'Accessibilità rimaste fuori (per esempio ridotte nel Dock).
        for (id, live) in liveByID where !seen.contains(id) {
            guard let app = appsByPID[live.pid] else { continue }
            seen.insert(id)
            add(id: id, app: app, live: live, frame: live.frame, title: live.title, spaces: SpacesManager.spaceIDs(forWindow: id))
        }
        for live in liveWithoutID {
            guard let app = appsByPID[live.pid] else { continue }
            add(id: nil, app: app, live: live, frame: live.frame, title: live.title, spaces: [])
        }
        return result
    }

    /// Riepilogo a schermo dopo il salvataggio, in parole semplici.
    private func reportSaved(_ scene: SavedScene) {
        var lines: [ActivityReport.Line] = []
        let windows = scene.windows.count
        let apps = Set(scene.windows.map(\.bundleID)).count
        lines.append(.init(text: "\(windows) \(windows == 1 ? "finestra" : "finestre") di \(apps) app, ognuna con il suo monitor e la sua scrivania"))
        for display in scene.displays {
            var parts: [String] = []
            if let count = display.spaceCount { parts.append("\(count) \(count == 1 ? "scrivania" : "scrivanie")") }
            if let mode = display.mode { parts.append("risoluzione \(mode.label)") }
            let label = Engine.label(display.name, builtin: display.isBuiltin)
            lines.append(.init(text: parts.isEmpty ? label : "\(label): " + parts.joined(separator: ", ")))
        }
        let chromeWindows = scene.windows.filter { $0.bundleID == BrowserBridge.chromeID }
        if !chromeWindows.isEmpty {
            let names = Dictionary(BrowserBridge.chromeProfiles().map { ($0.directory, $0.name) }, uniquingKeysWith: { first, _ in first })
            var perProfile: [String: Int] = [:]
            for window in chromeWindows { perProfile[window.chromeProfile.map { names[$0] ?? $0 } ?? "profilo non riconosciuto", default: 0] += 1 }
            let tabCount = chromeWindows.reduce(0) { $0 + ($1.tabs?.count ?? 0) }
            let profilesText = perProfile.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append(.init(text: "Chrome: \(chromeWindows.count) \(chromeWindows.count == 1 ? "finestra" : "finestre") con \(tabCount) schede, per profilo: \(profilesText)"))
            lines.append(.init(text: Engine.chromeZoomSummary(scene.chromeZoom)))
            let withoutTabs = chromeWindows.filter { ($0.tabs ?? []).isEmpty }
            if withoutTabs.count == chromeWindows.count {
                lines.append(.init(text: "Non sono riuscito a leggere le schede di Chrome, quindi non ho salvato né le schede né lo zoom. Mandami la diagnostica: ci guardo io.", warning: true))
            } else if !withoutTabs.isEmpty {
                let names = withoutTabs.map { "“" + BrowserBridge.readableTitle($0.title, profiles: BrowserBridge.chromeProfiles()) + "”" }
                lines.append(.init(text: "Di \(Engine.shortList(names)) non ho letto le schede: la rimetto a posto, ma se la chiudi non potrò riaprirla.", tone: .info))
            }
            if BrowserBridge.chromeProfiles().count > 1 {
                let unknown = chromeWindows.filter { $0.chromeProfile == nil }.count
                if unknown > 0 {
                    lines.append(.init(text: "Di \(unknown) \(unknown == 1 ? "finestra" : "finestre") di Chrome non ho capito il profilo: il loro zoom potrebbe non tornare.", warning: true))
                }
            }
        }
        let finderWindows = scene.windows.filter { $0.bundleID == FinderBridge.bundleID }
        let unknownFolders = finderWindows.filter { $0.folderPath == nil }
        if !unknownFolders.isEmpty {
            let names = unknownFolders.map { $0.title.isEmpty ? "una finestra senza titolo" : "“\($0.title)”" }
            lines.append(.init(text: "Del Finder non so quale cartella mostra " + Engine.shortList(names) + ": la rimetto a posto, ma se la chiudi non potrò riaprirla.", tone: .info))
        }
        if windows == 0 {
            lines.append(.init(text: "Non ho trovato finestre: controlla il permesso di Accessibilità dal menu dell'ancora.", warning: true))
        }
        onActivity?(ActivityReport(
            kind: lines.contains(where: \.warning) ? .warning : .success,
            title: "Scena “\(scene.name)” salvata",
            subtitle: "Per richiamarla: clic sull'ancora in alto, poi sul suo nome",
            lines: lines
        ))
    }

    /// "Schermo del Mac" per il monitor integrato, il nome per gli altri.
    static func label(_ name: String, builtin: Bool) -> String {
        builtin ? "Schermo del Mac" : name
    }

    static func percent(_ level: Double) -> Int {
        Int((pow(1.2, level) * 100).rounded())
    }

    /// Zoom di Chrome salvati in una scena, in una riga.
    static func chromeZoomSummary(_ zoom: [String: [String: Double]]?) -> String {
        guard let zoom else { return "Zoom di Chrome: non salvato" }
        var custom: [String: Int] = [:]
        for hosts in zoom.values {
            for (host, level) in hosts where abs(level) > 0.01 { custom[host] = percent(level) }
        }
        guard !custom.isEmpty else { return "Zoom di Chrome: tutti i siti al 100%" }
        let items = custom.sorted { $0.key < $1.key }.map { "\($0.key) al \($0.value)%" }
        return "Zoom di Chrome: " + shortList(items)
    }

    /// Chrome scrive lo zoom nelle preferenze con qualche secondo di ritardo:
    /// poco dopo il salvataggio lo rileggo e aggiorno la scena se è cambiato.
    private func scheduleChromeZoomRefresh(id: UUID) {
        Task { @MainActor in
            await Input.pause(12)
            guard let scene = self.store.scene(id: id) else { return }
            let profiles = BrowserBridge.chromeProfiles()
            let zoom = Engine.chromeZoom(for: scene.windows, profiles: profiles)
            guard zoom != scene.chromeZoom else { return }
            self.store.update(id: id) { $0.chromeZoom = zoom }
            Log.write("Zoom di Chrome della scena \"\(scene.name)\" aggiornato dopo il salvataggio")
            guard !self.isBusy else { return }
            self.onActivity?(ActivityReport(
                kind: .success,
                title: "Zoom di Chrome aggiornato in “\(scene.name)”",
                subtitle: "Chrome lo salva con qualche secondo di ritardo",
                lines: [.init(text: Engine.chromeZoomSummary(zoom))]
            ))
        }
    }

    /// Zoom di Chrome dei siti aperti nelle finestre, per profilo, letto dalle preferenze di Chrome.
    static func chromeZoom(for windows: [SavedWindow], profiles: [ChromeProfile]) -> [String: [String: Double]]? {
        var chromeZoom: [String: [String: Double]] = [:]
        var levelsByProfile: [String: (defaultLevel: Double, hosts: [String: Double])] = [:]
        for window in windows where window.bundleID == BrowserBridge.chromeID {
            let profile = window.chromeProfile ?? profiles.first?.directory ?? "Default"
            if levelsByProfile[profile] == nil { levelsByProfile[profile] = BrowserBridge.chromeZoomLevels(profile: profile) }
            guard let levels = levelsByProfile[profile] else { continue }
            for address in window.tabs ?? [] {
                guard let host = BrowserBridge.host(of: address) else { continue }
                chromeZoom[profile, default: [:]][host] = levels.hosts[host] ?? levels.defaultLevel
            }
        }
        return chromeZoom.isEmpty ? nil : chromeZoom
    }

    // MARK: Richiamo

    func recall(id: UUID) {
        guard let scene = store.scene(id: id) else { return }
        Task { @MainActor in await self.apply(scene) }
    }

    func apply(_ scene: SavedScene) async {
        guard !isBusy else { return }
        guard WindowManager.isTrusted(prompt: false) else {
            Log.write("Scena \"\(scene.name)\" non richiamata: manca il permesso di Accessibilità")
            refreshState()
            onActivity?(ActivityReport(
                kind: .failure,
                title: "Non posso richiamare “\(scene.name)”",
                subtitle: "Manca il permesso di Accessibilità",
                lines: [.init(text: "Clic sull'ancora in alto, poi \"Ripara il permesso di Accessibilità…\"", warning: true)]
            ))
            return
        }
        isBusy = true
        refreshState()
        let started = Date()
        var notes: [ActivityReport.Line] = []
        let workingReport = ActivityReport(
            kind: .working,
            title: "Sto ripristinando “\(scene.name)”…",
            subtitle: "Non toccare mouse e tastiera: ci vuole qualche secondo"
        )
        onActivity?(workingReport)
        let mouse = Input.mouseLocation
        Log.write("Richiamo la scena \"\(scene.name)\"")

        // 1. Scala dei monitor
        var displays = DisplayManager.activeDisplays()
        var modeChanged = false
        for saved in scene.displays {
            guard let target = saved.mode else { continue }
            guard let live = displays.first(where: { $0.key == saved.key }) else {
                Log.write("Scala: \(saved.name) non è collegato")
                notes.append(.init(text: "\(saved.name) non è collegato: le finestre che stavano lì restano dove sono.", tone: .info))
                continue
            }
            let current = live.mode?.label ?? "?"
            if let mode = live.mode, mode.sameResolution(as: target) {
                Log.write("Scala di \(live.name): già \(current)")
                continue
            }
            let changed = DisplayManager.setMode(target, on: live.id)
            Log.write("Scala di \(live.name): da \(current) a \(target.label) \(changed ? "cambiata" : "NON cambiata")")
            if changed {
                modeChanged = true
                notes.append(.init(text: "\(Engine.label(live.name, builtin: live.isBuiltin)): risoluzione rimessa a \(target.label)"))
            } else {
                notes.append(.init(text: "\(Engine.label(live.name, builtin: live.isBuiltin)): non sono riuscito a rimettere la risoluzione \(target.label)", warning: true))
            }
        }
        if modeChanged {
            await Input.pause(2)
            displays = DisplayManager.activeDisplays()
        }

        // 2. Numero di scrivanie
        if manageSpaces, SpacesManager.isAvailable {
            var wanted: [CGDirectDisplayID: Int] = [:]
            for saved in scene.displays {
                guard let count = saved.spaceCount, let live = displays.first(where: { $0.key == saved.key }) else { continue }
                wanted[live.id] = count
            }
            if !wanted.isEmpty {
                let before = SpacesManager.layouts(for: displays)
                _ = await SpacesManager.adjustSpaces(wanted: wanted, displays: displays)
                let after = SpacesManager.layouts(for: displays)
                for saved in scene.displays {
                    guard let count = saved.spaceCount,
                          let live = displays.first(where: { $0.key == saved.key }),
                          let had = before[live.id]?.count, let have = after[live.id]?.count else { continue }
                    let label = Engine.label(live.name, builtin: live.isBuiltin)
                    if have == count, had != count {
                        let diff = abs(have - had)
                        let what = have > had
                            ? (diff == 1 ? "aggiunta 1 scrivania" : "aggiunte \(diff) scrivanie")
                            : (diff == 1 ? "tolta 1 scrivania" : "tolte \(diff) scrivanie")
                        notes.append(.init(text: "\(label): \(what), ora sono \(have) come nella scena"))
                    } else if have != count {
                        notes.append(.init(text: "\(label): nella scena le scrivanie sono \(count), adesso sono \(have). Non sono riuscito a sistemarle.", warning: true))
                    }
                }
            }
        }

        // 3. App chiuse da aprire e app nascoste da mostrare
        let wantedApps = Set(scene.windows.map(\.bundleID))
        let running = WindowManager.regularApps()
        for app in running where app.isHidden {
            if let bundleID = app.bundleIdentifier, wantedApps.contains(bundleID) { _ = app.unhide() }
        }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        var launched = 0
        var launchedNames: [String] = []
        for app in scene.apps where !runningIDs.contains(app.bundleID) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                Log.write("App non trovata: \(app.name)")
                notes.append(.init(text: "\(app.name) non è installata su questo Mac.", tone: .info))
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                launched += 1
                launchedNames.append(app.name)
            } catch {
                Log.write("Non riesco ad aprire \(app.name): \(error.localizedDescription)")
            }
        }
        if launched > 0 {
            notes.append(.init(text: "Ho aperto " + Engine.shortList(launchedNames)))
            await Input.pause(4)
        }

        // 4. Dove sono adesso le finestre (senza cambiare scrivania)
        let usesChrome = scene.windows.contains { $0.bundleID == BrowserBridge.chromeID }
        let profiles = usesChrome ? BrowserBridge.chromeProfiles() : []
        var knownProfiles: [CGWindowID: String] = [:]
        for window in scene.windows {
            if let id = window.windowID, let profile = window.chromeProfile { knownProfiles[id] = profile }
        }
        var tracked = inventory(displays: displays, profiles: profiles, knownProfiles: knownProfiles)
        if usesChrome { Engine.attachChromeTabs(&tracked, profiles: profiles) }
        Log.write("Finestre trovate: \(tracked.count). " + Engine.describe(tracked))

        // 5. Abbinamento tra finestre salvate e finestre aperte
        let first = match(scene.windows, with: tracked)
        var assignments = first.assignments
        Log.write("Abbinate \(assignments.count) finestre su \(scene.windows.count). Da riaprire: "
                  + first.unmatched.map { "\($0.appName) \"\($0.title)\"" }.joined(separator: ", "))

        // 6. Finestre da riaprire: cartelle, documenti, finestre del browser con le schede
        let reopened = first.unmatched.filter { reopen($0) }
        if !reopened.isEmpty {
            await Input.pause(3)
            let known = Set(tracked.compactMap(\.windowID))
            let fresh = inventory(displays: displays, profiles: profiles, excluding: known)
            var more = match(reopened, with: fresh, strict: false).assignments
            for index in more.indices { more[index].needsFrame = true }
            assignments += more
            if !more.isEmpty {
                notes.append(.init(text: "Ho riaperto " + Engine.shortList(more.map { self.windowName($0.saved, profiles: profiles) })))
            }
        }

        // 7. Finestre ridotte nel Dock: tornano tutte su (anche se al salvataggio erano nel Dock).
        //    Finestre a tutto schermo che nella scena non lo erano: tornano normali.
        var stateChanged = false
        var restoredFromDock: [String] = []
        for index in assignments.indices {
            if assignments[index].tracked.live == nil, let id = assignments[index].tracked.windowID {
                assignments[index].tracked.live = WindowManager.resolve(windowID: id, pid: assignments[index].tracked.pid)
            }
            let assignment = assignments[index]
            guard let live = assignment.tracked.live else { continue }
            if assignment.tracked.isMinimized || live.isMinimized {
                WindowManager.setMinimized(live.element, false)
                assignments[index].needsFrame = true
                stateChanged = true
                restoredFromDock.append(windowName(assignment.saved, profiles: profiles))
            }
            if assignment.tracked.isFullScreen, assignment.saved.fullScreen != true {
                WindowManager.setFullScreen(live.element, false)
                assignments[index].needsFrame = true
                stateChanged = true
            }
        }
        if stateChanged {
            await Input.pause(1.2)
            refresh(&assignments, displays: displays)
        }
        if !restoredFromDock.isEmpty {
            notes.append(.init(text: "Ho riportato su dal Dock " + Engine.shortList(restoredFromDock)))
        }

        // 8. Monitor e scrivania giusti
        await relocate(&assignments, scene: scene, displays: displays)
        let misplaced = assignments.filter { $0.saved.desktop != nil && $0.saved.desktop != $0.tracked.desktop }
        if !misplaced.isEmpty {
            Log.write("Finestre rimaste sulla scrivania sbagliata: " + misplaced.map {
                "\($0.saved.appName) (voluta \($0.saved.desktop ?? 0), attuale \($0.tracked.desktop ?? 0))"
            }.joined(separator: ", "))
        }

        // 9. Posizione e dimensione
        await placeFrames(&assignments, scene: scene, displays: displays)

        // 9b. Schede di Chrome che mancano nelle finestre già aperte: le apro in quella finestra.
        //     Una scheda già aperta in un'altra finestra dello stesso profilo non la riapro:
        //     per siti come WhatsApp Web una seconda copia stacca la prima.
        var openPages: [String: Set<String>] = [:]
        var openHosts: [String: Set<String>] = [:]
        for window in tracked where window.bundleID == BrowserBridge.chromeID {
            let profile = window.chromeProfile ?? "?"
            for address in window.tabs ?? [] {
                openPages[profile, default: []].insert(Engine.pageKey(address))
                if let host = BrowserBridge.host(of: address) { openHosts[profile, default: []].insert(host.lowercased()) }
            }
        }
        var tabsReopened: [String] = []
        for index in assignments.indices where assignments[index].saved.bundleID == BrowserBridge.chromeID {
            let saved = assignments[index].saved
            guard let openTabs = assignments[index].tracked.tabs else { continue }
            let profile = saved.chromeProfile ?? assignments[index].tracked.chromeProfile ?? "?"
            let present = Set(openTabs.map(Engine.pageKey)).union(openPages[profile] ?? [])
            var seen = Set<String>()
            let missingTabs = (saved.tabs ?? []).filter { address in
                let key = Engine.pageKey(address)
                if let host = BrowserBridge.host(of: address)?.lowercased(), Engine.singleSessionHosts.contains(host),
                   openHosts[profile]?.contains(host) == true {
                    return false
                }
                return !BrowserBridge.isMeeting(address) && !present.contains(key) && seen.insert(key).inserted
            }
            guard !missingTabs.isEmpty,
                  let live = await liveWindow(for: &assignments[index].tracked, displays: displays) else { continue }
            WindowManager.raise(live)
            await Input.pause(0.5)
            guard BrowserBridge.focusedChromeWindow(pid: live.pid)?.id == live.windowID else {
                Log.write("Schede mancanti in \"\(saved.title)\": la finestra non è andata in primo piano")
                continue
            }
            BrowserBridge.openChromeTabs(profile: saved.chromeProfile ?? assignments[index].tracked.chromeProfile, urls: missingTabs)
            await Input.pause(1.2)
            Log.write("Schede riaperte in \"\(saved.title)\": " + missingTabs.joined(separator: " "))
            tabsReopened.append("\(windowName(saved, profiles: profiles)) (\(missingTabs.count))")
        }
        if !tabsReopened.isEmpty {
            notes.append(.init(text: "Ho riaperto le schede che mancavano in " + Engine.shortList(tabsReopened)))
        }

        // 10. Pagina giusta di Impostazioni di Sistema
        for assignment in assignments where assignment.saved.bundleID == Engine.settingsID {
            let title = assignment.saved.title
            if !title.isEmpty, assignment.tracked.title != title, let live = assignment.tracked.live {
                WindowManager.selectSidebarItem(titled: title, in: live.element)
            }
        }

        // 11. Finestre che nella scena erano a tutto schermo (quelle nel Dock restano su)
        for assignment in assignments {
            guard let live = assignment.tracked.live else { continue }
            if assignment.saved.fullScreen == true, !assignment.tracked.isFullScreen {
                WindowManager.setFullScreen(live.element, true)
            }
        }

        // 11b. Finestre che non fanno parte della scena, sulle scrivanie dove la scena ha finestre:
        //      le riduco nel Dock, così su ogni scrivania restano su solo quelle della scena.
        if minimizeOthers {
            let reduced = minimizeOutsiders(assignments, displays: displays)
            if !reduced.isEmpty {
                notes.append(.init(text: "Ho ridotto nel Dock le finestre fuori dalla scena: " + Engine.countedList(reduced)))
            }
        }

        // 12. Zoom di Chrome, sito per sito
        let chromeZoom = await applyChromeZoom(scene, displays: displays, profiles: profiles)
        if usesChrome {
            if scene.chromeZoom == nil {
                notes.append(.init(text: "Questa scena non contiene lo zoom di Chrome, quindi non l'ho toccato.", tone: .info))
            } else if !chromeZoom.applied.isEmpty {
                notes.append(.init(text: "Zoom di Chrome rimesso: " + Engine.shortList(chromeZoom.applied)))
            } else if chromeZoom.failed.isEmpty {
                notes.append(.init(text: "Zoom di Chrome già come nella scena"))
            }
            if !chromeZoom.failed.isEmpty {
                notes.append(.init(text: "Zoom di Chrome non rimesso su " + Engine.shortList(chromeZoom.failed) + ".", warning: true))
            }
        }

        // 13. Zoom delle altre app, come scelto nella scena
        var appZoomDone: [String] = []
        for (bundleID, steps) in scene.appZoom ?? [:] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            if let live = assignments.first(where: { $0.saved.bundleID == bundleID })?.tracked.live {
                WindowManager.raise(live)
                await Input.pause(0.2)
            }
            let done = await ZoomManager.setZoom(pid: app.processIdentifier, steps: steps, appName: app.localizedName ?? bundleID)
            Log.write("Zoom di \(app.localizedName ?? bundleID): \(steps >= 0 ? "+" : "")\(steps) \(done ? "applicato" : "NON applicato")")
            if done {
                appZoomDone.append(app.localizedName ?? bundleID)
            } else {
                notes.append(.init(text: "Zoom di \(app.localizedName ?? bundleID) non rimesso: non trovo i comandi di zoom nel suo menu.", warning: true))
            }
        }
        if !appZoomDone.isEmpty {
            notes.append(.init(text: "Zoom rimesso in " + Engine.shortList(appZoomDone)))
        }

        // 14. Scrivanie visibili come al salvataggio
        if manageSpaces {
            for saved in scene.displays {
                guard let desktop = saved.currentDesktop, let live = displays.first(where: { $0.key == saved.key }) else { continue }
                await SpacesManager.switchDesktop(on: live, to: desktop - 1, displays: displays)
            }
        }
        Input.moveMouse(to: mouse)

        activeSceneID = scene.id
        lastFingerprint = DisplayManager.fingerprint(DisplayManager.activeDisplays())
        isBusy = false
        refreshState()
        Log.write("Scena \"\(scene.name)\" richiamata: \(assignments.count) finestre sistemate, \(launched) app aperte, \(reopened.count) finestre riaperte")

        // Riepilogo a schermo in parole semplici: cosa è a posto, cosa non è riuscito, cosa sapere.
        var lines: [ActivityReport.Line] = []
        let total = scene.windows.count
        let placedKeys = Set(assignments.map { Engine.windowKey($0.saved) })
        let reopenedKeys = Set(reopened.map { Engine.windowKey($0) })
        let missing = scene.windows.filter { !placedKeys.contains(Engine.windowKey($0)) }
        // Finestre riaperte ma non sistemate: questo è un problema.
        let notPlaced = missing.filter { reopenedKeys.contains(Engine.windowKey($0)) }
        // Finestre chiuse dopo il salvataggio, che non so o non devo riaprire: è normale.
        let closed = missing.filter { !reopenedKeys.contains(Engine.windowKey($0)) }

        let wrongDesktop = assignments.filter { $0.saved.desktop != nil && $0.saved.desktop != $0.tracked.desktop }
        let inPlace = assignments.count - wrongDesktop.count
        if missing.isEmpty && wrongDesktop.isEmpty {
            lines.append(.init(text: "Tutte le \(total) finestre della scena sono al loro posto."))
        } else if assignments.isEmpty {
            lines.append(.init(text: "Nessuna finestra della scena è aperta in questo momento.", tone: .info))
        } else if inPlace > 0 {
            lines.append(.init(text: "\(inPlace) finestre su \(total) sono al loro posto."))
        }
        if !closed.isEmpty {
            let names = Engine.countedList(closed.map { self.windowName($0, profiles: profiles) })
            lines.append(.init(
                text: "\(closed.count == 1 ? "Una finestra della scena l'hai chiusa" : "\(closed.count) finestre della scena le hai chiuse") dopo il salvataggio e non la riapro: \(names).",
                tone: .info))
        }
        if !notPlaced.isEmpty {
            notes.append(.init(text: "Ho riaperto " + Engine.countedList(notPlaced.map { self.windowName($0, profiles: profiles) }) + ", ma non sono riuscito a rimetterle al loro posto.", warning: true))
        }
        for assignment in wrongDesktop.prefix(3) {
            notes.append(.init(text: "\(windowName(assignment.saved, profiles: profiles)): non sono riuscito a portarla sulla scrivania \(assignment.saved.desktop ?? 0).", warning: true))
        }
        lines += notes.filter { $0.tone == .done } + notes.filter { $0.tone == .warning } + notes.filter { $0.tone == .info }

        // La scena è vecchia (finestre chiuse, zoom di Chrome mancante): propongo di aggiornarla con un clic.
        let stale = !closed.isEmpty || (usesChrome && scene.chromeZoom == nil)
        if stale {
            lines.append(.init(text: "Se adesso il Mac è come lo vuoi, aggiorna la scena: Ormeggio dimentica le finestre chiuse e salva lo zoom di Chrome.", tone: .info))
        }
        let hasWarnings = lines.contains(where: \.warning)
        let sceneName = scene.name
        let sceneAuto = scene.autoApply
        var updateScene: (@MainActor () -> Void)?
        if stale {
            updateScene = { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.saveScene(name: sceneName, autoApply: sceneAuto) }
            }
        }
        let title = hasWarnings ? "“\(sceneName)”: qualcosa non è tornato" : "“\(sceneName)” è al suo posto"
        let actionTitle: String? = stale ? "Aggiorna “\(sceneName)” con il Mac com'è adesso" : nil
        onActivity?(ActivityReport(
            kind: hasWarnings ? .warning : .success,
            title: title,
            subtitle: nil,
            lines: lines,
            actionTitle: actionTitle,
            action: updateScene
        ))
    }

    /// Elenco con i doppioni contati: "Finder (2), Chrome “Meet”".
    static func countedList(_ items: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            if counts[item] == nil { order.append(item) }
            counts[item, default: 0] += 1
        }
        let parts = order.map { counts[$0, default: 1] > 1 ? "\($0) (\(counts[$0, default: 1]))" : $0 }
        let shown = parts.prefix(4).joined(separator: ", ")
        return parts.count > 4 ? "\(shown) e altre \(parts.count - 4)" : shown
    }

    /// Nome leggibile di una finestra salvata: app e titolo, senza il profilo di Chrome.
    private func windowName(_ window: SavedWindow, profiles: [ChromeProfile]) -> String {
        let app = window.bundleID == BrowserBridge.chromeID ? "Chrome" : window.appName
        var title = window.title
        if window.bundleID == FinderBridge.bundleID, let path = window.folderPath {
            title = FinderBridge.displayName(of: path)
        }
        title = BrowserBridge.readableTitle(title, profiles: profiles)
        return title.isEmpty || title == app ? app : "\(app) “\(title)”"
    }

    /// Chiave per riconoscere la stessa finestra salvata.
    private static func windowKey(_ window: SavedWindow) -> String {
        "\(window.bundleID)|\(window.index)|\(window.displayKey)|\(window.title)"
    }

    /// Elenco breve: i primi tre nomi, poi "e altri N".
    static func shortList(_ items: [String]) -> String {
        var unique: [String] = []
        for item in items where !unique.contains(item) { unique.append(item) }
        let shown = unique.prefix(3).joined(separator: ", ")
        return unique.count > 3 ? "\(shown) e altri \(unique.count - 3)" : shown
    }

    /// Siti che reggono una sola copia aperta: aprirne una seconda stacca la prima.
    static let singleSessionHosts: Set<String> = ["web.whatsapp.com", "web.telegram.org", "messages.google.com"]

    /// App di riunione: le loro finestre non le riduco mai nel Dock.
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager"
    ]

    /// Riduce nel Dock le finestre aperte che non fanno parte della scena, ma solo sulle scrivanie
    /// (monitor e numero di scrivania) dove la scena ha almeno una finestra. Le riunioni restano su.
    /// Restituisce i nomi delle app delle finestre ridotte.
    private func minimizeOutsiders(_ assignments: [Assignment], displays: [LiveDisplay]) -> [String] {
        var sceneDesktops = Set<String>()
        var sceneIDs = Set<CGWindowID>()
        for assignment in assignments {
            if let id = assignment.tracked.windowID { sceneIDs.insert(id) }
            if let desktop = assignment.saved.desktop { sceneDesktops.insert("\(assignment.saved.displayKey)#\(desktop)") }
        }
        guard !sceneDesktops.isEmpty else { return [] }
        let profiles = BrowserBridge.chromeProfiles()
        var current = inventory(displays: displays, profiles: profiles)
        Engine.attachChromeTabs(&current, profiles: profiles)
        var elements: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var reduced: [String] = []
        for window in current {
            guard let id = window.windowID, !sceneIDs.contains(id),
                  !window.isMinimized, !window.isFullScreen,
                  let desktop = window.desktop, sceneDesktops.contains("\(window.displayKey)#\(desktop)") else { continue }
            if Engine.meetingApps.contains(window.bundleID) || (window.tabs ?? []).contains(where: BrowserBridge.isMeeting) {
                Log.write("Fuori dalla scena ma lasciata su (riunione): \(window.appName) \"\(window.title)\"")
                continue
            }
            var element = window.live?.element
            if element == nil {
                if elements[window.pid] == nil { elements[window.pid] = WindowManager.elementsOnAllDesktops(pid: window.pid) }
                element = elements[window.pid]?[id]
            }
            guard let element else {
                Log.write("Fuori dalla scena, non raggiungibile: \(window.appName) \"\(window.title)\"")
                continue
            }
            WindowManager.setMinimized(element, true)
            reduced.append(window.appName)
            Log.write("Ridotta nel Dock perché fuori dalla scena: \(window.appName) \"\(window.title)\" (\(window.displayKey), scrivania \(desktop))")
        }
        return reduced
    }

    /// Rimette lo zoom di Chrome dei siti della scena, dove è diverso da quello che Chrome ha salvato.
    /// Lo zoom di Chrome vale per sito e per profilo: per cambiarlo apro un momento una finestra del sito
    /// nel profilo giusto, sistemo lo zoom con i comandi del menu Vista e la richiudo.
    /// Le finestre aperte restano come sono e non serve nessun permesso oltre all'Accessibilità.
    private func applyChromeZoom(_ scene: SavedScene, displays: [LiveDisplay], profiles: [ChromeProfile]) async -> (applied: [String], failed: [String]) {
        var applied: [String] = []
        var failed: [String] = []
        guard let wanted = scene.chromeZoom,
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: BrowserBridge.chromeID).first else { return (applied, failed) }
        for (profile, hosts) in wanted.sorted(by: { $0.key < $1.key }) {
            let current = BrowserBridge.chromeZoomLevels(profile: profile)
            for (host, level) in hosts.sorted(by: { $0.key < $1.key }) {
                let now = current.hosts[host] ?? current.defaultLevel
                guard abs(now - level) > 0.01 else { continue }
                // Una pagina di solo testo dello stesso sito (robots.txt): lo zoom di Chrome vale per tutto il sito,
                // e così non apro una seconda copia dell'app web. Aprire di nuovo WhatsApp Web, per esempio,
                // staccherebbe quella già aperta.
                let address = "https://\(host)/robots.txt"
                let steps = BrowserBridge.chromeSteps(from: current.defaultLevel, to: level)
                let done = await zoomInTemporaryWindow(address: address, profile: profile, steps: steps,
                                                       pid: chrome.processIdentifier, profiles: profiles)
                Log.write("Zoom di Chrome su \(host) (profilo \(profile)): da \(Engine.percent(now))% a \(Engine.percent(level))% \(done ? "applicato" : "NON applicato")")
                if done {
                    applied.append("\(host) al \(Engine.percent(level))%")
                } else {
                    failed.append(host)
                }
            }
        }
        return (applied, failed)
    }

    /// Apre una finestra di Chrome sul sito nel profilo indicato, ne sistema lo zoom e la chiude.
    private func zoomInTemporaryWindow(address: String, profile: String, steps: Int,
                                       pid: pid_t, profiles: [ChromeProfile]) async -> Bool {
        let before = BrowserBridge.focusedChromeWindow(pid: pid)?.id
        BrowserBridge.openChromeWindow(profile: profile, urls: [address])
        var opened: CGWindowID?
        for _ in 0..<24 {
            await Input.pause(0.25)
            if let front = BrowserBridge.focusedChromeWindow(pid: pid), let id = front.id, id != before {
                opened = id
                break
            }
        }
        guard let opened else {
            Log.write("Zoom di Chrome: la finestra per \(address) non si è aperta")
            return false
        }
        // Lascio caricare la pagina: Chrome applica lo zoom al sito della pagina mostrata.
        await Input.pause(2)
        var done = false
        let front = BrowserBridge.focusedChromeWindow(pid: pid)
        let frontProfile = BrowserBridge.profile(fromTitle: front?.title ?? "", profiles: profiles)
        if profiles.count > 1, let frontProfile, frontProfile != profile {
            Log.write("Zoom di Chrome: la finestra aperta è del profilo \(frontProfile) invece di \(profile)")
        } else if front?.id == opened {
            done = await ZoomManager.setZoom(pid: pid, steps: steps, appName: "Chrome")
            await Input.pause(0.3)
        } else {
            Log.write("Zoom di Chrome: la finestra aperta non è più in primo piano")
        }
        if !BrowserBridge.closeWindow(id: opened, pid: pid) {
            Log.write("Zoom di Chrome: non riesco a chiudere la finestra aperta per lo zoom")
        }
        return done
    }

    func setAppZoom(id: UUID, _ values: [String: Int]) {
        store.update(id: id) { $0.appZoom = values.isEmpty ? nil : values }
    }

    /// Aggiorna posizione, monitor e scrivania delle finestre già abbinate.
    private func refresh(_ assignments: inout [Assignment], displays: [LiveDisplay]) {
        let current = inventory(displays: displays, profiles: [])
        var byID: [CGWindowID: TrackedWindow] = [:]
        for window in current {
            if let id = window.windowID { byID[id] = window }
        }
        for index in assignments.indices {
            guard let id = assignments[index].tracked.windowID, var fresh = byID[id] else { continue }
            fresh.chromeProfile = assignments[index].tracked.chromeProfile
            assignments[index].tracked = fresh
        }
    }

    // MARK: Abbinamento

    /// Abbina per identificativo (stessa finestra ancora aperta), poi per titolo, poi nell'ordine.
    /// Abbina le finestre salvate a quelle aperte: prima per numero di finestra, poi le finestre di Chrome
    /// per profilo e schede, poi per titolo, infine in ordine. Con strict, una finestra che si può riaprire
    /// (cartella, documento, finestra del browser con le sue schede) non viene data a una finestra qualsiasi.
    func match(_ saved: [SavedWindow], with tracked: [TrackedWindow], strict: Bool = true) -> (assignments: [Assignment], unmatched: [SavedWindow]) {
        var available = tracked
        var assignments: [Assignment] = []

        var pending: [SavedWindow] = []
        for window in saved {
            if let id = window.windowID,
               let found = available.firstIndex(where: { $0.windowID == id && $0.bundleID == window.bundleID }) {
                assignments.append(Assignment(saved: window, tracked: available.remove(at: found)))
            } else {
                pending.append(window)
            }
        }

        // Chrome: stesso profilo e schede in comune, dalla coppia più simile.
        var pairs: [(saved: Int, tracked: Int, score: Double)] = []
        for (savedIndex, window) in pending.enumerated() where window.bundleID == BrowserBridge.chromeID {
            let savedTabs = window.tabs ?? []
            guard !savedTabs.isEmpty else { continue }
            for (trackedIndex, candidate) in available.enumerated() where candidate.bundleID == BrowserBridge.chromeID {
                guard let openTabs = candidate.tabs, Engine.sameProfile(window, candidate) else { continue }
                let score = Engine.tabSimilarity(savedTabs, openTabs)
                if score > 0 { pairs.append((saved: savedIndex, tracked: trackedIndex, score: score)) }
            }
        }
        var usedSaved = Set<Int>()
        var usedTracked = Set<Int>()
        for pair in pairs.sorted(by: { $0.score > $1.score }) where !usedSaved.contains(pair.saved) && !usedTracked.contains(pair.tracked) {
            usedSaved.insert(pair.saved)
            usedTracked.insert(pair.tracked)
            assignments.append(Assignment(saved: pending[pair.saved], tracked: available[pair.tracked]))
        }
        pending = pending.enumerated().filter { !usedSaved.contains($0.offset) }.map(\.element)
        available = available.enumerated().filter { !usedTracked.contains($0.offset) }.map(\.element)

        var stillPending: [SavedWindow] = []
        for window in pending {
            if !window.title.isEmpty,
               let found = available.firstIndex(where: {
                   $0.bundleID == window.bundleID && $0.title == window.title && Engine.sameProfile(window, $0)
               }) {
                assignments.append(Assignment(saved: window, tracked: available.remove(at: found)))
            } else {
                stillPending.append(window)
            }
        }

        var unmatched: [SavedWindow] = []
        for window in stillPending.sorted(by: { $0.index < $1.index }) {
            // Cartelle, documenti e finestre del browser si riaprono: non li assegno a una finestra qualsiasi.
            let browserTabs = (window.tabs ?? []).filter { !BrowserBridge.isMeeting($0) }
            let reopenable = window.folderPath != nil || window.documentURL != nil
                || (BrowserBridge.isBrowser(window.bundleID) && !browserTabs.isEmpty)
            if !(strict && reopenable),
               let found = available.firstIndex(where: { $0.bundleID == window.bundleID && Engine.sameProfile(window, $0) }) {
                assignments.append(Assignment(saved: window, tracked: available.remove(at: found)))
            } else {
                unmatched.append(window)
            }
        }
        return (assignments, unmatched)
    }

    /// Una pagina riconosciuta per sito e percorso, senza parametri e senza #: così la posta in arrivo
    /// e un messaggio aperto nella stessa casella contano come la stessa scheda.
    static func pageKey(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return address }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// Quanto si somigliano due elenchi di schede: pagine in comune, poi siti in comune.
    static func tabSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let leftPages = Set(lhs.map(pageKey))
        let rightPages = Set(rhs.map(pageKey))
        let leftHosts = Set(lhs.compactMap { BrowserBridge.host(of: $0) })
        let rightHosts = Set(rhs.compactMap { BrowserBridge.host(of: $0) })
        let pages = Double(leftPages.intersection(rightPages).count) / Double(max(leftPages.union(rightPages).count, 1))
        let hosts = Double(leftHosts.intersection(rightHosts).count) / Double(max(leftHosts.union(rightHosts).count, 1))
        return pages + hosts / 2
    }

    /// Aggiunge alle finestre di Chrome aperte le loro schede e il loro profilo, dai file di sessione.
    static func attachChromeTabs(_ tracked: inout [TrackedWindow], profiles: [ChromeProfile]) {
        let chromeIndices = tracked.indices.filter { tracked[$0].bundleID == BrowserBridge.chromeID }
        guard !chromeIndices.isEmpty else { return }
        let found = ChromeSession.assign(
            chromeIndices.map { (title: tracked[$0].title, frame: tracked[$0].frame, profile: tracked[$0].chromeProfile) },
            sessions: ChromeSession.windows(profiles: profiles)
        )
        for (position, index) in chromeIndices.enumerated() {
            guard let session = found[position] else { continue }
            tracked[index].tabs = session.tabs
            if tracked[index].chromeProfile == nil { tracked[index].chromeProfile = session.profile }
        }
    }

    private static func sameProfile(_ saved: SavedWindow, _ tracked: TrackedWindow) -> Bool {
        guard let wanted = saved.chromeProfile, let found = tracked.chromeProfile else { return true }
        return wanted == found
    }

    /// Riapre una finestra che manca. Restituisce true se ha aperto qualcosa.
    private func reopen(_ saved: SavedWindow) -> Bool {
        if let path = saved.folderPath {
            FinderBridge.open(folder: path)
            return true
        }
        if BrowserBridge.isBrowser(saved.bundleID) {
            // Senza schede note aprirei una finestra vuota; le riunioni finite non le riapro.
            let tabs = (saved.tabs ?? []).filter { !BrowserBridge.isMeeting($0) }
            guard !tabs.isEmpty else { return false }
            if saved.bundleID == BrowserBridge.chromeID {
                BrowserBridge.openChromeWindow(profile: saved.chromeProfile, urls: tabs)
            } else {
                BrowserBridge.openSafariWindow(urls: tabs)
            }
            return true
        }
        if let raw = saved.documentURL, let url = URL(string: raw), url.isFileURL,
           FileManager.default.fileExists(atPath: url.path),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
            return true
        }
        return false
    }

    // MARK: Spostamenti

    /// Restituisce l'elemento di Accessibilità della finestra. Se macOS non lo espone,
    /// mostra la scrivania della finestra e lo cerca di nuovo.
    private func liveWindow(for tracked: inout TrackedWindow, displays: [LiveDisplay]) async -> LiveWindow? {
        if let live = tracked.live { return live }
        guard let id = tracked.windowID else { return nil }
        await reveal(tracked, displays: displays)
        await Input.pause(0.2)
        if let live = WindowManager.resolve(windowID: id, pid: tracked.pid) {
            tracked.live = live
            return live
        }
        Log.write("Finestra di \(tracked.appName) non raggiungibile")
        return nil
    }

    /// Porta ogni finestra sul monitor e sulla scrivania della scena.
    ///
    /// macOS non lascia alle app spostare una finestra su un'altra scrivania, ma quando una finestra
    /// passa a un altro monitor la mette sempre sulla scrivania visibile di quel monitor. Quindi:
    /// - finestra sul monitor sbagliato: porto il monitor giusto sulla scrivania giusta, poi ci sposto la finestra;
    /// - finestra sulla scrivania sbagliata dello stesso monitor: la appoggio un attimo sull'altro monitor,
    ///   porto il suo monitor sulla scrivania giusta e ce la rimetto.
    /// Con un monitor solo resta il trascinamento con ctrl + freccia.
    private func relocate(_ assignments: inout [Assignment], scene: SavedScene, displays: [LiveDisplay]) async {
        let fallback = displays.first(where: \.isBuiltin) ?? displays.first
        let useDesktops = manageSpaces && SpacesManager.isAvailable
        let order = assignments.indices.sorted { lhs, rhs in
            let left = assignments[lhs].saved
            let right = assignments[rhs].saved
            if left.displayKey != right.displayKey { return left.displayKey < right.displayKey }
            return (left.desktop ?? 0) < (right.desktop ?? 0)
        }
        for index in order {
            guard let target = displays.first(where: { $0.key == assignments[index].saved.displayKey }) ?? fallback else { continue }
            let wanted = useDesktops ? assignments[index].saved.desktop : nil
            let sameDisplay = assignments[index].tracked.displayKey == target.key
            let sameDesktop = wanted == nil || assignments[index].tracked.desktop == wanted
            if sameDisplay && sameDesktop { continue }
            if assignments[index].tracked.isFullScreen { continue }
            if let wanted, let count = SpacesManager.layouts(for: displays)[target.id]?.count, wanted > count {
                Log.write("\(assignments[index].saved.appName): la scrivania \(wanted) di \(target.name) non c'è (sono \(count))")
                continue
            }

            // La finestra deve essere raggiungibile: porto in vista la sua scrivania.
            if assignments[index].tracked.live == nil || !isOnVisibleDesktop(assignments[index].tracked, displays: displays) {
                await reveal(assignments[index].tracked, displays: displays)
                await Input.pause(0.2)
                if let id = assignments[index].tracked.windowID,
                   let live = WindowManager.resolve(windowID: id, pid: assignments[index].tracked.pid) {
                    assignments[index].tracked.live = live
                }
            }
            guard let live = assignments[index].tracked.live else {
                Log.write("\(assignments[index].saved.appName): finestra non raggiungibile, non la sposto")
                continue
            }
            let name = "\(assignments[index].saved.appName) \"\(assignments[index].saved.title)\""
            let frame = targetFrame(for: assignments[index].saved, on: target, scene: scene)

            let targetSpace = wanted.flatMap { desktop in SpacesManager.layouts(for: displays)[target.id]?.spaceIDs[safe: desktop - 1] }
            if !sameDisplay {
                if let wanted, !(await SpacesManager.switchDesktop(on: target, to: wanted - 1, displays: displays)) {
                    Log.write("\(name): non riesco a portare \(target.name) sulla scrivania \(wanted)")
                }
                WindowManager.setFrame(live.element, to: frame)
                if let id = assignments[index].tracked.windowID, let targetSpace {
                    _ = await SpacesManager.waitForWindow(id, onSpace: targetSpace)
                } else {
                    await Input.pause(0.4)
                }
                Log.write("\(name): portata su \(target.name)" + (wanted.map { ", scrivania \($0)" } ?? ""))
            } else if let wanted, let other = displays.first(where: { $0.id != target.id }) {
                // Passaggio per l'altro monitor.
                let size = CGSize(width: min(frame.width, other.bounds.width * 0.8), height: min(frame.height, other.bounds.height * 0.8))
                let parking = CGRect(x: other.bounds.midX - size.width / 2, y: other.bounds.midY - size.height / 2,
                                     width: size.width, height: size.height)
                WindowManager.setFrame(live.element, to: parking)
                await Input.pause(0.5)
                let switched = await SpacesManager.switchDesktop(on: target, to: wanted - 1, displays: displays)
                await Input.pause(0.2)
                WindowManager.setFrame(live.element, to: frame)
                if let id = assignments[index].tracked.windowID, let targetSpace {
                    _ = await SpacesManager.waitForWindow(id, onSpace: targetSpace)
                } else {
                    await Input.pause(0.5)
                }
                Log.write("\(name): passata per \(other.name) e rimessa su \(target.name), scrivania \(wanted)" + (switched ? "" : " (il cambio di scrivania non ha risposto)"))
            } else if let wanted {
                _ = await SpacesManager.moveWindow(live, on: target, to: wanted - 1, displays: displays)
            }

            // Controllo dove è finita davvero.
            assignments[index].tracked.frame = frame
            assignments[index].needsFrame = true
            if let id = assignments[index].tracked.windowID {
                let spaces = SpacesManager.spaceIDs(forWindow: id)
                let layouts = SpacesManager.layouts(for: displays)
                for display in displays {
                    guard let layout = layouts[display.id],
                          let position = layout.spaceIDs.firstIndex(where: { spaces.contains($0) }) else { continue }
                    assignments[index].tracked.displayKey = display.key
                    assignments[index].tracked.desktop = position + 1
                }
                let arrived = assignments[index].tracked.displayKey == target.key
                    && (wanted == nil || assignments[index].tracked.desktop == wanted)
                Log.write("\(name): ora su \(assignments[index].tracked.displayKey) scrivania \(assignments[index].tracked.desktop.map { "\($0)" } ?? "?")" + (arrived ? "" : " (NON al suo posto)"))
            }
        }
    }

    /// Imposta posizione e dimensione solo dove serve, cambiando scrivania solo se indispensabile.
    private func placeFrames(_ assignments: inout [Assignment], scene: SavedScene, displays: [LiveDisplay]) async {
        let fallback = displays.first(where: \.isBuiltin) ?? displays.first
        var targets: [Int: CGRect] = [:]
        for index in assignments.indices {
            guard let display = displays.first(where: { $0.key == assignments[index].saved.displayKey }) ?? fallback else { continue }
            let target = targetFrame(for: assignments[index].saved, on: display, scene: scene)
            if assignments[index].needsFrame || !Engine.close(assignments[index].tracked.frame, target) {
                targets[index] = target
            }
        }
        guard !targets.isEmpty else { return }

        // Prima senza cambiare scrivania: per le finestre che macOS espone spesso basta.
        var pending: [Int] = []
        for (index, target) in targets {
            guard let live = assignments[index].tracked.live else {
                pending.append(index)
                continue
            }
            WindowManager.setFrame(live.element, to: target)
            if isOnVisibleDesktop(assignments[index].tracked, displays: displays) { continue }
            pending.append(index)
        }
        await Input.pause(0.3)

        // Verifico con il server delle finestre; dove non ha funzionato passo dalla scrivania.
        let actual = Dictionary(WindowManager.systemWindows().map { ($0.id, $0.bounds) }, uniquingKeysWith: { first, _ in first })
        let stillWrong = pending.filter { index in
            guard let id = assignments[index].tracked.windowID, let bounds = actual[id], let target = targets[index] else { return true }
            return !Engine.close(bounds, target)
        }
        let groups = Dictionary(grouping: stillWrong) { index in
            "\(assignments[index].tracked.displayKey)#\(assignments[index].tracked.desktop ?? 0)"
        }
        for key in groups.keys.sorted() {
            guard let indices = groups[key] else { continue }
            for index in indices {
                guard let target = targets[index],
                      let live = await liveWindow(for: &assignments[index].tracked, displays: displays) else { continue }
                if assignments[index].tracked.live != nil { await reveal(assignments[index].tracked, displays: displays) }
                WindowManager.setFrame(live.element, to: target)
            }
            await Input.pause(0.2)
        }
    }

    private func isOnVisibleDesktop(_ tracked: TrackedWindow, displays: [LiveDisplay]) -> Bool {
        guard let desktop = tracked.desktop,
              let display = displays.first(where: { $0.key == tracked.displayKey }),
              let current = SpacesManager.layouts(for: displays)[display.id]?.currentIndex else { return true }
        return desktop == current + 1
    }

    /// Mostra la scrivania su cui si trova la finestra.
    private func reveal(_ tracked: TrackedWindow, displays: [LiveDisplay]) async {
        guard let desktop = tracked.desktop,
              let display = displays.first(where: { $0.key == tracked.displayKey }) else { return }
        await SpacesManager.switchDesktop(on: display, to: desktop - 1, displays: displays)
    }

    private func targetFrame(for saved: SavedWindow, on display: LiveDisplay, scene: SavedScene) -> CGRect {
        let relative = saved.frame.cgRect
        let bounds = display.bounds
        var target: CGRect
        if display.key == saved.displayKey {
            target = CGRect(x: bounds.minX + relative.minX, y: bounds.minY + relative.minY,
                            width: relative.width, height: relative.height)
        } else {
            // Il monitor della scena non è collegato: porto la finestra in proporzione su quello disponibile.
            let original = scene.displays.first(where: { $0.key == saved.displayKey })?.bounds.cgRect ?? bounds
            let scaleX = bounds.width / max(original.width, 1)
            let scaleY = bounds.height / max(original.height, 1)
            target = CGRect(x: bounds.minX + relative.minX * scaleX, y: bounds.minY + relative.minY * scaleY,
                            width: relative.width * scaleX, height: relative.height * scaleY)
        }
        return Engine.clamp(target, to: bounds)
    }

    private static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 3 && abs(lhs.minY - rhs.minY) < 3
            && abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
    }

    // MARK: Diagnostica

    func diagnostics() -> String {
        let displays = DisplayManager.activeDisplays()
        let layouts = SpacesManager.layouts(for: displays)
        var lines: [String] = []
        lines.append("Ormeggio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Accessibilità: \(WindowManager.isTrusted(prompt: false) ? "concessa" : "NON concessa")")
        lines.append("Notifiche: \(Notifier.shared.statusText)")
        lines.append("Automazione Chrome: \(BrowserBridge.automationStatus(bundleID: BrowserBridge.chromeID)) · Finder: \(BrowserBridge.automationStatus(bundleID: FinderBridge.bundleID))")
        let sessions = ChromeSession.windows(profiles: BrowserBridge.chromeProfiles())
        lines.append("Chrome dai file di sessione: \(sessions.count) finestre, \(sessions.reduce(0) { $0 + $1.tabs.count }) schede (" + Set(sessions.map(\.profile)).sorted().joined(separator: ", ") + ")")
        lines.append("Lettura scrivanie: \(SpacesManager.isAvailable ? "disponibile" : "non disponibile")")
        lines.append("Scorciatoie ctrl + frecce: \(Engine.desktopShortcutsEnabled ? "attive" : "DISATTIVATE")")
        lines.append("Impronta monitor: \(DisplayManager.fingerprint(displays))")
        for display in displays {
            var line = "• \(display.name) [\(display.key)]"
            if let mode = display.mode {
                line += " · \(mode.width)×\(mode.height) punti, \(mode.pixelWidth)×\(mode.pixelHeight) pixel, \(Int(mode.refreshRate)) Hz"
            }
            if let layout = layouts[display.id] {
                line += " · \(layout.count) scrivanie"
                if let current = layout.currentIndex { line += ", visibile la \(current + 1)ª" }
                if let total = SpacesManager.totalSpaceCount(for: display, displays: displays), total > layout.count {
                    line += ", \(total - layout.count) app a tutto schermo"
                }
            }
            lines.append(line)
            lines.append("   scale disponibili: " + DisplayManager.availableScales(of: display.id).joined(separator: ", "))
        }
        let tracked = inventory(displays: displays, profiles: [])
        let exposed = tracked.filter { $0.live != nil }.count
        lines.append("Finestre su tutte le scrivanie: \(tracked.count), viste dall'Accessibilità: \(exposed)")
        let visible = tracked.filter { isOnVisibleDesktop($0, displays: displays) || $0.isMinimized }
        let perApp = Dictionary(grouping: visible, by: \.appName).map { name, windows in
            "\(name) \(windows.filter { $0.live != nil }.count) di \(windows.count)"
        }.sorted()
        lines.append("Sulle scrivanie visibili, viste dall'Accessibilità: " + perApp.joined(separator: ", "))
        lines.append("Finestre per scrivania: " + Engine.describe(tracked))
        let profiles = BrowserBridge.chromeProfiles()
        if !profiles.isEmpty {
            lines.append("Profili Chrome: \(profiles.map { "\($0.name) (\($0.directory))" }.joined(separator: ", "))")
        }
        lines.append("Scene salvate: \(store.scenes.count)")
        if let scene = activeScene { lines.append("Scena attiva: \(scene.name)") }
        return lines.joined(separator: "\n")
    }

    /// Testo completo da mandare all'assistenza: diagnostica, scene (senza indirizzi web) e registro.
    /// Diagnostica per l'assistenza. Con maxCharacters è la versione breve per la mail:
    /// senza l'elenco delle risoluzioni e con le ultime righe del registro che ci stanno.
    func supportReport(maxCharacters: Int? = nil) -> String {
        var summary = diagnostics()
        if maxCharacters != nil {
            summary = summary.split(separator: "\n").filter { !$0.hasPrefix("   scale disponibili") }.joined(separator: "\n")
        }
        var parts = ["=== Diagnostica ===", summary, "", "=== Scene ==="]
        for scene in store.scenes {
            parts.append("• \(scene.name) [\(scene.fingerprint)] automatica: \(scene.autoApply ? "sì" : "no"), salvata \(scene.savedAt)")
            for display in scene.displays {
                let desktops = display.spaceCount.map { "\($0)" } ?? "?"
                let visible = display.currentDesktop.map { "\($0)" } ?? "?"
                parts.append("   monitor \(display.name) [\(display.key)] \(display.mode?.label ?? "?"), scrivanie \(desktops), visibile \(visible)")
            }
            for window in scene.windows {
                var line = "   - \(window.appName) · monitor \(window.displayKey) · scrivania \(window.desktop.map { "\($0)" } ?? "tutte o ?")"
                line += " · \(Int(window.frame.width))×\(Int(window.frame.height))"
                if let id = window.windowID { line += " · id \(id)" }
                if let tabs = window.tabs { line += " · \(tabs.count) schede" }
                if let profile = window.chromeProfile { line += " · profilo \(profile)" }
                if window.folderPath != nil { line += " · cartella" }
                if window.documentURL != nil { line += " · documento" }
                if window.minimized == true { line += " · nel Dock" }
                if window.fullScreen == true { line += " · tutto schermo" }
                parts.append(line)
            }
        }
        parts.append("")
        let logLines = (try? String(contentsOf: Paths.log, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        guard let maxCharacters else {
            parts.append("=== Registro (ultime 400 righe) ===")
            parts.append(logLines.suffix(400).joined(separator: "\n"))
            return parts.joined(separator: "\n")
        }
        parts.append("=== Registro (ultime righe) ===")
        var head = parts.joined(separator: "\n")
        if head.count > maxCharacters { head = String(head.prefix(maxCharacters)) }
        var budget = maxCharacters - head.count
        var tail: [String] = []
        for line in logLines.reversed() {
            let cost = line.count + 1
            if cost > budget { break }
            tail.insert(line, at: 0)
            budget -= cost
        }
        return head + "\n" + tail.joined(separator: "\n")
    }

    static func describe(_ tracked: [TrackedWindow]) -> String {
        let groups = Dictionary(grouping: tracked) { window -> String in
            let place = window.isMinimized ? "Dock" : "scrivania \(window.desktop.map { "\($0)" } ?? "tutte")"
            return "\(window.displayKey) \(place)"
        }
        return groups.keys.sorted().map { key in
            "[\(key): " + (groups[key] ?? []).map { $0.appName }.joined(separator: ", ") + "]"
        }.joined(separator: " ")
    }

    /// Le scorciatoie "Sposta a sinistra/destra di uno spazio" (ctrl + frecce) sono attive?
    static var desktopShortcutsEnabled: Bool {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") else {
            return true
        }
        for key in ["79", "81"] {
            if let entry = hotkeys[key] as? [String: Any], let enabled = entry["enabled"] as? Bool, !enabled { return false }
        }
        return true
    }

    func suggestedName() -> String {
        let externals = DisplayManager.activeDisplays().filter { !$0.isBuiltin }
        if externals.isEmpty { return "Mac da solo" }
        return externals.map(\.name).joined(separator: " + ")
    }

    // MARK: Geometria

    static func display(for frame: CGRect, in displays: [LiveDisplay]) -> LiveDisplay? {
        var best: LiveDisplay?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = display.bounds.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        if best != nil { return best }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.min { distance($0.bounds, center) < distance($1.bounds, center) }
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = max(bounds.minX, min(result.minX, bounds.maxX - result.width))
        result.origin.y = max(bounds.minY, min(result.minY, bounds.maxY - result.height))
        return result
    }

    /// Abbina una finestra del Finder alla cartella che mostra (per titolo, poi per posizione).
    private static func folderIndex(title: String, frame: CGRect, in folders: [FinderWindowInfo]) -> Int? {
        guard !folders.isEmpty else { return nil }
        func gap(_ folder: FinderWindowInfo) -> CGFloat {
            abs(folder.frame.minX - frame.minX) + abs(folder.frame.minY - frame.minY)
                + abs(folder.frame.width - frame.width) + abs(folder.frame.height - frame.height)
        }
        let sameTitle = folders.indices.filter { !title.isEmpty && FinderBridge.displayName(of: folders[$0].path) == title }
        if let best = sameTitle.min(by: { gap(folders[$0]) < gap(folders[$1]) }) { return best }
        guard let best = folders.indices.min(by: { gap(folders[$0]) < gap(folders[$1]) }) else { return nil }
        return gap(folders[best]) < 80 ? best : nil
    }
}
