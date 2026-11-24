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
        let changed = fingerprint != lastFingerprint
        lastFingerprint = fingerprint
        guard changed, !isBusy else {
            refreshState()
            return
        }
        if let active = activeScene, active.fingerprint != fingerprint {
            activeSceneID = nil
        }
        refreshState()
        guard autoApplyEnabled, let scene = store.autoScene(for: fingerprint) else {
            Log.write("Monitor cambiati (\(reason)): nessuna scena automatica per questi monitor")
            return
        }
        Log.write("Richiamo automatico di \"\(scene.name)\" (\(reason))")
        await apply(scene)
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
        let finderFolders = runningIDs.contains(FinderBridge.bundleID) ? FinderBridge.openFolders() : []
        var chromeInfos = runningIDs.contains(BrowserBridge.chromeID) ? BrowserBridge.windows(bundleID: BrowserBridge.chromeID) : []
        var safariInfos = runningIDs.contains(BrowserBridge.safariID) ? BrowserBridge.windows(bundleID: BrowserBridge.safariID) : []
        let profiles = runningIDs.contains(BrowserBridge.chromeID) ? BrowserBridge.chromeProfiles() : []

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

        var unusedFolders = finderFolders
        var counters: [String: Int] = [:]
        var windows: [SavedWindow] = []
        for item in tracked {
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
                if let match = Engine.folderIndex(title: item.title, frame: item.frame, in: unusedFolders) {
                    let folder = unusedFolders.remove(at: match)
                    saved.folderPath = folder.path
                    if saved.title.isEmpty { saved.title = FinderBridge.displayName(of: folder.path) }
                }
            case BrowserBridge.chromeID:
                if let match = BrowserBridge.match(title: item.title, frame: item.frame, in: chromeInfos) {
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
        var otherDesktopTitles: [pid_t: [CGWindowID: String]] = [:]

        func add(id: CGWindowID?, app: NSRunningApplication, live: LiveWindow?, frame: CGRect, title: String, spaces: [Int]) {
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
                isFullScreen: live?.isFullScreen ?? false
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
                if title.isEmpty, app.bundleIdentifier == BrowserBridge.chromeID {
                    if otherDesktopTitles[app.processIdentifier] == nil {
                        otherDesktopTitles[app.processIdentifier] = WindowManager.titlesOnAllDesktops(pid: app.processIdentifier)
                    }
                    title = otherDesktopTitles[app.processIdentifier]?[system.id] ?? ""
                }
                add(id: system.id, app: app, live: nil, frame: system.bounds, title: title, spaces: spaces)
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
            lines.append(.init(text: Engine.chromeZoomSummary(scene.chromeZoom)))
            let withoutTabs = chromeWindows.filter { ($0.tabs ?? []).isEmpty }
            if withoutTabs.count == chromeWindows.count {
                lines.append(.init(text: "Non riesco a leggere le schede di Chrome. In Impostazioni di Sistema > Privacy e sicurezza > Automazione, lascia che Ormeggio controlli Google Chrome.", warning: true))
            } else if !withoutTabs.isEmpty {
                lines.append(.init(text: "Di \(withoutTabs.count) \(withoutTabs.count == 1 ? "finestra" : "finestre") di Chrome non ho letto le schede: se le chiudi non potrò riaprirle.", warning: true))
            }
            if BrowserBridge.chromeProfiles().count > 1 {
                let unknown = chromeWindows.filter { $0.chromeProfile == nil }.count
                if unknown > 0 {
                    lines.append(.init(text: "Di \(unknown) \(unknown == 1 ? "finestra" : "finestre") di Chrome non ho capito il profilo: il loro zoom potrebbe non tornare.", warning: true))
                }
            }
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
        onActivity?(ActivityReport(
            kind: .working,
            title: "Sto ripristinando “\(scene.name)”…",
            subtitle: "Non toccare mouse e tastiera: ci vuole qualche secondo"
        ))
        let mouse = Input.mouseLocation
        Log.write("Richiamo la scena \"\(scene.name)\"")

        // 1. Scala dei monitor
        var displays = DisplayManager.activeDisplays()
        var modeChanged = false
        for saved in scene.displays {
            guard let target = saved.mode else { continue }
            guard let live = displays.first(where: { $0.key == saved.key }) else {
                Log.write("Scala: \(saved.name) non è collegato")
                notes.append(.init(text: "\(saved.name) non è collegato: le finestre che stavano lì le lascio dove sono.", warning: true))
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
                notes.append(.init(text: "\(app.name) non è installata su questo Mac", warning: true))
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
        let tracked = inventory(displays: displays, profiles: profiles, knownProfiles: knownProfiles)
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
            var more = match(reopened, with: fresh).assignments
            for index in more.indices { more[index].needsFrame = true }
            assignments += more
            if !more.isEmpty {
                notes.append(.init(text: "Ho riaperto " + Engine.shortList(more.map { self.windowName($0.saved, profiles: profiles) })))
            }
        }

        // 7. Finestre ridotte nel Dock o a tutto schermo che nella scena non lo erano
        var stateChanged = false
        for index in assignments.indices {
            let assignment = assignments[index]
            guard let live = assignment.tracked.live else { continue }
            if assignment.tracked.isMinimized, assignment.saved.minimized != true {
                WindowManager.setMinimized(live.element, false)
                assignments[index].needsFrame = true
                stateChanged = true
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

        // 10. Pagina giusta di Impostazioni di Sistema
        for assignment in assignments where assignment.saved.bundleID == Engine.settingsID {
            let title = assignment.saved.title
            if !title.isEmpty, assignment.tracked.title != title, let live = assignment.tracked.live {
                WindowManager.selectSidebarItem(titled: title, in: live.element)
            }
        }

        // 11. Finestre che nella scena erano ridotte nel Dock o a tutto schermo
        for assignment in assignments {
            guard let live = assignment.tracked.live else { continue }
            if assignment.saved.minimized == true, !assignment.tracked.isMinimized {
                WindowManager.setMinimized(live.element, true)
            }
            if assignment.saved.fullScreen == true, !assignment.tracked.isFullScreen {
                WindowManager.setFullScreen(live.element, true)
            }
        }

        // 12. Zoom di Chrome, sito per sito
        let chromeZoom = await applyChromeZoom(scene, displays: displays, profiles: profiles)
        if usesChrome {
            if scene.chromeZoom == nil {
                notes.append(.init(text: "In questa scena lo zoom di Chrome non è salvato: risalvala per memorizzarlo.", warning: true))
            } else if !chromeZoom.applied.isEmpty {
                notes.append(.init(text: "Zoom di Chrome rimesso: " + Engine.shortList(chromeZoom.applied)))
            } else if chromeZoom.failed.isEmpty {
                notes.append(.init(text: "Zoom di Chrome già come nella scena"))
            }
            if !chromeZoom.failed.isEmpty {
                notes.append(.init(text: "Zoom di Chrome non rimesso su " + Engine.shortList(chromeZoom.failed) + ": non trovo la scheda nel profilo giusto.", warning: true))
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

        // Riepilogo a schermo: prima le finestre, poi il resto, in fondo cosa non è andato e perché.
        var lines: [ActivityReport.Line] = []
        let total = scene.windows.count
        lines.append(.init(text: assignments.count == total
            ? "Tutte le \(total) finestre al loro posto"
            : "\(assignments.count) finestre su \(total) al loro posto"))
        let placedKeys = Set(assignments.map { Engine.windowKey($0.saved) })
        let reopenedKeys = Set(reopened.map { Engine.windowKey($0) })
        let missing = scene.windows.filter { !placedKeys.contains(Engine.windowKey($0)) }
        for window in missing.prefix(4) {
            notes.append(.init(text: missingReason(window, reopened: reopenedKeys.contains(Engine.windowKey(window)), profiles: profiles), warning: true))
        }
        if missing.count > 4 {
            notes.append(.init(text: "Altre \(missing.count - 4) finestre non ritrovate", warning: true))
        }
        let wrongDesktop = assignments.filter { $0.saved.desktop != nil && $0.saved.desktop != $0.tracked.desktop }
        for assignment in wrongDesktop.prefix(3) {
            notes.append(.init(text: "\(windowName(assignment.saved, profiles: profiles)): non sono riuscito a portarla sulla scrivania \(assignment.saved.desktop ?? 0)", warning: true))
        }
        lines += notes.filter { !$0.warning } + notes.filter(\.warning)
        let seconds = max(1, Int(Date().timeIntervalSince(started).rounded()))
        let hasWarnings = lines.contains(where: \.warning)
        onActivity?(ActivityReport(
            kind: hasWarnings ? .warning : .success,
            title: hasWarnings ? "Scena “\(scene.name)” ripristinata in parte" : "Scena “\(scene.name)” ripristinata",
            subtitle: "Ci ho messo \(seconds) \(seconds == 1 ? "secondo" : "secondi")",
            lines: lines
        ))
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

    /// Perché una finestra della scena non è tornata, in parole semplici.
    private func missingReason(_ window: SavedWindow, reopened: Bool, profiles: [ChromeProfile]) -> String {
        let name = windowName(window, profiles: profiles)
        if BrowserBridge.isBrowser(window.bundleID) {
            let tabs = window.tabs ?? []
            if tabs.isEmpty { return "\(name): era chiusa e non so quali schede avesse, quindi non l'ho riaperta" }
            if tabs.allSatisfy({ BrowserBridge.isMeeting($0) }) { return "\(name): era una riunione finita, non la riapro" }
        }
        if window.bundleID == FinderBridge.bundleID, window.folderPath == nil {
            return "\(name): era chiusa e non so quale cartella mostrasse"
        }
        if reopened { return "\(name): l'ho riaperta ma non sono riuscito a metterla al suo posto" }
        return "\(name): era chiusa e questa app non mi permette di riaprirla"
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

    /// Rimette lo zoom di Chrome dei siti della scena.
    /// I siti con uno zoom diverso dal normale li sistemo sempre: Chrome scrive le preferenze
    /// con qualche secondo di ritardo, quindi quello che leggo può non essere aggiornato.
    /// Lo zoom di Chrome vale per sito e per profilo: prima di cambiarlo controllo che la finestra
    /// in primo piano sia del profilo giusto.
    private func applyChromeZoom(_ scene: SavedScene, displays: [LiveDisplay], profiles: [ChromeProfile]) async -> (applied: [String], failed: [String]) {
        var applied: [String] = []
        var failed: [String] = []
        guard let wanted = scene.chromeZoom,
              let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: BrowserBridge.chromeID).first else { return (applied, failed) }
        for (profile, hosts) in wanted.sorted(by: { $0.key < $1.key }) {
            let current = BrowserBridge.chromeZoomLevels(profile: profile)
            for (host, level) in hosts.sorted(by: { $0.key < $1.key }) {
                let now = current.hosts[host] ?? current.defaultLevel
                let custom = abs(level - current.defaultLevel) > 0.01
                guard custom || abs(now - level) > 0.01 else { continue }
                // La finestra della scena con quel sito, nel profilo giusto.
                let saved = scene.windows.first { window in
                    window.bundleID == BrowserBridge.chromeID
                        && (window.chromeProfile ?? profile) == profile
                        && (window.tabs ?? []).contains { BrowserBridge.host(of: $0) == host }
                }
                let frame = saved.flatMap { window in
                    displays.first(where: { $0.key == window.displayKey }).map {
                        self.targetFrame(for: window, on: $0, scene: scene)
                    }
                }
                let candidates = BrowserBridge.chromeCandidates(host: host, tabs: saved?.tabs ?? [], near: frame)
                guard !candidates.isEmpty else {
                    Log.write("Zoom di Chrome su \(host): nessuna scheda aperta con questo sito")
                    continue
                }
                // Il profilo lo verifico solo se so di quale profilo era la finestra salvata.
                let checkProfile = profiles.count > 1 && saved?.chromeProfile != nil
                var focused = false
                var previousTab: Int?
                for candidate in candidates.prefix(5) {
                    guard case .focused(let previous) = BrowserBridge.focusChromeTab(in: candidate, host: host) else { continue }
                    await Input.pause(0.8)
                    if checkProfile, let front = BrowserBridge.frontChromeProfile(pid: chrome.processIdentifier, profiles: profiles), front != profile {
                        Log.write("Zoom di Chrome su \(host): la finestra \"\(candidate.title)\" è del profilo \(front), cerco quella del profilo \(profile)")
                        if let previous { BrowserBridge.restoreChromeTab(previous) }
                        continue
                    }
                    focused = true
                    previousTab = previous
                    break
                }
                guard focused else {
                    Log.write("Zoom di Chrome su \(host): nessuna finestra del profilo \(profile) con questo sito")
                    failed.append(host)
                    continue
                }
                let steps = BrowserBridge.chromeSteps(from: current.defaultLevel, to: level)
                let done = await ZoomManager.setZoom(pid: chrome.processIdentifier, steps: steps, appName: "Chrome \(host)")
                if let previousTab {
                    await Input.pause(0.2)
                    BrowserBridge.restoreChromeTab(previousTab)
                }
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
    func match(_ saved: [SavedWindow], with tracked: [TrackedWindow]) -> (assignments: [Assignment], unmatched: [SavedWindow]) {
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
            // Cartelle e documenti si riaprono: non li assegno a una finestra qualsiasi della stessa app.
            let reopenable = window.folderPath != nil || window.documentURL != nil
            if !reopenable,
               let found = available.firstIndex(where: { $0.bundleID == window.bundleID && Engine.sameProfile(window, $0) }) {
                assignments.append(Assignment(saved: window, tracked: available.remove(at: found)))
            } else {
                unmatched.append(window)
            }
        }
        return (assignments, unmatched)
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
    private func relocate(_ assignments: inout [Assignment], scene: SavedScene, displays: [LiveDisplay]) async {
        let fallback = displays.first(where: \.isBuiltin) ?? displays.first

        // Monitor sbagliato: sposto la finestra sul monitor giusto.
        for index in assignments.indices {
            let target = displays.first(where: { $0.key == assignments[index].saved.displayKey }) ?? fallback
            guard let target, assignments[index].tracked.displayKey != target.key else { continue }
            if assignments[index].tracked.live == nil || !isOnVisibleDesktop(assignments[index].tracked, displays: displays) {
                await reveal(assignments[index].tracked, displays: displays)
                if let id = assignments[index].tracked.windowID,
                   let live = WindowManager.resolve(windowID: id, pid: assignments[index].tracked.pid) {
                    assignments[index].tracked.live = live
                }
            }
            guard let live = assignments[index].tracked.live else { continue }
            let frame = targetFrame(for: assignments[index].saved, on: target, scene: scene)
            WindowManager.setFrame(live.element, to: frame)
            await Input.pause(0.2)
            assignments[index].tracked.displayKey = target.key
            assignments[index].tracked.frame = frame
            assignments[index].tracked.desktop = SpacesManager.layouts(for: displays)[target.id]?.currentIndex.map { $0 + 1 }
            assignments[index].needsFrame = true
        }

        // Scrivania sbagliata: trascino la finestra sulla scrivania giusta.
        guard manageSpaces, SpacesManager.isAvailable else { return }
        let order = assignments.indices.sorted { lhs, rhs in
            let left = assignments[lhs].tracked
            let right = assignments[rhs].tracked
            if left.displayKey != right.displayKey { return left.displayKey < right.displayKey }
            return (left.desktop ?? 0) < (right.desktop ?? 0)
        }
        for index in order {
            guard let wanted = assignments[index].saved.desktop, let current = assignments[index].tracked.desktop, wanted != current,
                  let display = displays.first(where: { $0.key == assignments[index].tracked.displayKey }),
                  let layout = SpacesManager.layouts(for: displays)[display.id], wanted <= layout.count else { continue }
            guard await SpacesManager.switchDesktop(on: display, to: current - 1, displays: displays) else { continue }
            await Input.pause(0.2)
            // Dopo il cambio di scrivania la finestra è visibile: ne prendo l'elemento aggiornato.
            if let id = assignments[index].tracked.windowID,
               let live = WindowManager.resolve(windowID: id, pid: assignments[index].tracked.pid) {
                assignments[index].tracked.live = live
            }
            guard let live = assignments[index].tracked.live else { continue }
            if await SpacesManager.moveWindow(live, on: display, to: wanted - 1, displays: displays) {
                assignments[index].tracked.desktop = wanted
                assignments[index].needsFrame = true
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
        lines.append("Automazione Chrome: \(BrowserBridge.automationStatus(bundleID: BrowserBridge.chromeID)) · Finder: \(BrowserBridge.automationStatus(bundleID: FinderBridge.bundleID))")
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
    func supportReport() -> String {
        var parts = ["=== Diagnostica ===", diagnostics(), "", "=== Scene ==="]
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
        parts.append("=== Registro (ultime 400 righe) ===")
        if let log = try? String(contentsOf: Paths.log, encoding: .utf8) {
            parts.append(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(400).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
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
