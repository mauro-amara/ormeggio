import AppKit

enum EngineState: Equatable {
    case active(String)
    case idle
    case working
    case needsPermission
}

/// Una finestra trovata durante il giro delle scrivanie.
struct TrackedWindow {
    let live: LiveWindow
    var displayKey: String
    /// Scrivania del monitor (da 1). Nil se è su tutte le scrivanie o non si sa.
    var desktop: Int?
    var chromeProfile: String?
}

/// Una finestra salvata abbinata alla finestra aperta che la rappresenta.
struct Assignment {
    let saved: SavedWindow
    var tracked: TrackedWindow
}

/// Salva e richiama le scene.
@MainActor
final class Engine {
    let store: SceneStore
    var onStateChange: (@MainActor () -> Void)?
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
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let displays = DisplayManager.activeDisplays()
        let layouts = SpacesManager.layouts(for: displays)
        let tracked = WindowManager.windows(of: app).compactMap { window -> TrackedWindow? in
            guard let display = Engine.display(for: window.frame, in: displays) else { return nil }
            let desktop = layouts[display.id]?.currentIndex.map { $0 + 1 }
            return TrackedWindow(live: window, displayKey: display.key, desktop: desktop, chromeProfile: nil)
        }
        let result = match(scene.windows.filter { $0.bundleID == bundleID }, with: tracked)
        guard !result.assignments.isEmpty else { return }
        isBusy = true
        refreshState()
        var assignments = result.assignments
        await relocate(&assignments, scene: scene, displays: displays)
        await placeFrames(assignments, scene: scene, displays: displays)
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
        var scene = await capture(name: name)
        scene.autoApply = autoApply
        store.save(scene)
        activeSceneID = store.scene(named: name)?.id
        lastFingerprint = scene.fingerprint
        isBusy = false
        refreshState()
        Log.write("Scena \"\(name)\" salvata: \(scene.windows.count) finestre, \(scene.apps.count) app")
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

    private func capture(name: String) async -> SavedScene {
        let displays = DisplayManager.activeDisplays()
        let layouts = SpacesManager.layouts(for: displays)
        let mouse = Input.mouseLocation

        let running = WindowManager.regularApps()
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let finderFolders = runningIDs.contains(FinderBridge.bundleID) ? FinderBridge.openFolders() : []
        var chromeInfos = runningIDs.contains(BrowserBridge.chromeID) ? BrowserBridge.windows(bundleID: BrowserBridge.chromeID) : []
        var safariInfos = runningIDs.contains(BrowserBridge.safariID) ? BrowserBridge.windows(bundleID: BrowserBridge.safariID) : []
        let profiles = runningIDs.contains(BrowserBridge.chromeID) ? BrowserBridge.chromeProfiles() : []

        let tracked = await inventory(displays: displays, profiles: profiles, visitAllDesktops: manageSpaces)
        Input.moveMouse(to: mouse)

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
            let window = item.live
            guard let display = displays.first(where: { $0.key == item.displayKey }) else { continue }
            let relative = CGRect(
                x: window.frame.minX - display.bounds.minX,
                y: window.frame.minY - display.bounds.minY,
                width: window.frame.width,
                height: window.frame.height
            )
            let index = counters[window.bundleID, default: 0]
            counters[window.bundleID] = index + 1
            var saved = SavedWindow(
                bundleID: window.bundleID,
                appName: window.appName,
                title: window.title,
                index: index,
                displayKey: display.key,
                frame: CodableRect(relative),
                desktop: item.desktop,
                windowID: window.windowID,
                documentURL: window.documentURL,
                chromeProfile: item.chromeProfile
            )
            switch window.bundleID {
            case FinderBridge.bundleID:
                if let match = Engine.folderIndex(for: window, in: unusedFolders) {
                    saved.folderPath = unusedFolders.remove(at: match).path
                }
            case BrowserBridge.chromeID:
                if let match = BrowserBridge.match(window, in: chromeInfos) {
                    saved.tabs = chromeInfos.remove(at: match).urls
                }
            case BrowserBridge.safariID:
                if let match = BrowserBridge.match(window, in: safariInfos) {
                    saved.tabs = safariInfos.remove(at: match).urls
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

        return SavedScene(
            id: UUID(),
            name: name,
            fingerprint: DisplayManager.fingerprint(displays),
            autoApply: false,
            displays: savedDisplays,
            apps: apps,
            windows: windows,
            savedAt: Date()
        )
    }

    // MARK: Giro delle scrivanie

    /// Trova le finestre aperte e su quale monitor e scrivania si trovano.
    /// Con visitAllDesktops passa da tutte le scrivanie, perché macOS mostra solo le finestre di quelle visibili.
    private func inventory(displays: [LiveDisplay], profiles: [ChromeProfile], visitAllDesktops: Bool,
                           excluding: Set<CGWindowID> = []) async -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        var seen = excluding
        let initial = SpacesManager.layouts(for: displays)

        func collect(only displayKey: String?, assumedDesktop: (LiveDisplay) -> Int?) {
            let layouts = SpacesManager.layouts(for: displays)
            for app in WindowManager.regularApps() {
                for window in WindowManager.windows(of: app) {
                    if let id = window.windowID, seen.contains(id) { continue }
                    guard let display = Engine.display(for: window.frame, in: displays) else { continue }
                    if let displayKey, display.key != displayKey { continue }
                    var desktop = assumedDesktop(display)
                    if let id = window.windowID {
                        seen.insert(id)
                        let spaces = SpacesManager.spaceIDs(forWindow: id)
                        if spaces.count > 1 {
                            desktop = nil
                        } else if let space = spaces.first, let index = layouts[display.id]?.spaceIDs.firstIndex(of: space) {
                            desktop = index + 1
                        }
                    }
                    var profile: String?
                    if window.bundleID == BrowserBridge.chromeID, !profiles.isEmpty {
                        profile = BrowserBridge.detectProfile(of: window, profiles: profiles)
                    }
                    result.append(TrackedWindow(live: window, displayKey: display.key, desktop: desktop, chromeProfile: profile))
                }
            }
        }

        collect(only: nil) { initial[$0.id]?.currentIndex.map { $0 + 1 } }
        guard visitAllDesktops, SpacesManager.isAvailable else { return result }

        for display in displays {
            guard let layout = initial[display.id], layout.count > 1, let current = layout.currentIndex else { continue }
            for index in layout.spaceIDs.indices where index != current {
                guard await SpacesManager.switchDesktop(on: display, to: index, displays: displays) else { continue }
                await Input.pause(0.25)
                collect(only: display.key) { _ in index + 1 }
            }
            await SpacesManager.switchDesktop(on: display, to: current, displays: displays)
        }
        return result
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
            return
        }
        isBusy = true
        refreshState()
        let mouse = Input.mouseLocation
        Log.write("Richiamo la scena \"\(scene.name)\"")

        // 1. Scala dei monitor
        var displays = DisplayManager.activeDisplays()
        var modeChanged = false
        for saved in scene.displays {
            guard let target = saved.mode, let live = displays.first(where: { $0.key == saved.key }) else { continue }
            if DisplayManager.setMode(target, on: live.id) { modeChanged = true }
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
                _ = await SpacesManager.adjustSpaces(wanted: wanted, displays: displays)
            }
        }

        // 3. App chiuse
        let running = Set(WindowManager.regularApps().compactMap(\.bundleIdentifier))
        var launched = 0
        for app in scene.apps where !running.contains(app.bundleID) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                Log.write("App non trovata: \(app.name)")
                continue
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                launched += 1
            } catch {
                Log.write("Non riesco ad aprire \(app.name): \(error.localizedDescription)")
            }
        }
        if launched > 0 { await Input.pause(4) }

        // 4. Dove sono adesso le finestre
        let usesChrome = scene.windows.contains { $0.bundleID == BrowserBridge.chromeID }
        let profiles = usesChrome ? BrowserBridge.chromeProfiles() : []
        let tracked = await inventory(displays: displays, profiles: profiles, visitAllDesktops: manageSpaces)
        Log.write("Finestre trovate: \(tracked.count). " + Engine.describe(tracked))

        // 5. Abbinamento tra finestre salvate e finestre aperte
        let first = match(scene.windows, with: tracked)
        var assignments = first.assignments
        Log.write("Abbinate \(assignments.count) finestre su \(scene.windows.count). Da riaprire: \(first.unmatched.map { "\($0.appName) \"\($0.title)\"" }.joined(separator: ", "))")

        // 6. Finestre da riaprire: cartelle, documenti, finestre del browser con le schede
        let reopened = first.unmatched.filter { reopen($0) }
        if !reopened.isEmpty {
            await Input.pause(3)
            let known = Set(tracked.compactMap { $0.live.windowID })
            let fresh = await inventory(displays: displays, profiles: profiles, visitAllDesktops: false, excluding: known)
            assignments += match(reopened, with: fresh).assignments
        }

        // 7. Monitor e scrivania giusti
        await relocate(&assignments, scene: scene, displays: displays)
        let misplaced = assignments.filter { $0.saved.desktop != nil && $0.saved.desktop != $0.tracked.desktop }
        if !misplaced.isEmpty {
            Log.write("Finestre rimaste sulla scrivania sbagliata: " + misplaced.map {
                "\($0.saved.appName) (voluta \($0.saved.desktop ?? 0), attuale \($0.tracked.desktop ?? 0))"
            }.joined(separator: ", "))
        }

        // 8. Posizione e dimensione
        await placeFrames(assignments, scene: scene, displays: displays)

        // 9. Pagina giusta di Impostazioni di Sistema
        for assignment in assignments where assignment.saved.bundleID == Engine.settingsID {
            let title = assignment.saved.title
            if !title.isEmpty, assignment.tracked.live.title != title {
                WindowManager.selectSidebarItem(titled: title, in: assignment.tracked.live.element)
            }
        }

        // 10. Scrivanie visibili come al salvataggio
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
    }

    // MARK: Abbinamento

    /// Abbina per identificativo (stessa finestra ancora aperta), poi per titolo, poi nell'ordine.
    func match(_ saved: [SavedWindow], with tracked: [TrackedWindow]) -> (assignments: [Assignment], unmatched: [SavedWindow]) {
        var available = tracked
        var assignments: [Assignment] = []

        var pending: [SavedWindow] = []
        for window in saved {
            if let id = window.windowID,
               let found = available.firstIndex(where: { $0.live.windowID == id && $0.live.bundleID == window.bundleID }) {
                assignments.append(Assignment(saved: window, tracked: available.remove(at: found)))
            } else {
                pending.append(window)
            }
        }

        var stillPending: [SavedWindow] = []
        for window in pending {
            if !window.title.isEmpty,
               let found = available.firstIndex(where: {
                   $0.live.bundleID == window.bundleID && $0.live.title == window.title && Engine.sameProfile(window, $0)
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
               let found = available.firstIndex(where: { $0.live.bundleID == window.bundleID && Engine.sameProfile(window, $0) }) {
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
        if saved.bundleID == BrowserBridge.chromeID {
            BrowserBridge.openChromeWindow(profile: saved.chromeProfile, urls: saved.tabs ?? [])
            return true
        }
        if saved.bundleID == BrowserBridge.safariID, let tabs = saved.tabs, !tabs.isEmpty {
            BrowserBridge.openSafariWindow(urls: tabs)
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

    /// Porta ogni finestra sul monitor e sulla scrivania della scena.
    private func relocate(_ assignments: inout [Assignment], scene: SavedScene, displays: [LiveDisplay]) async {
        let fallback = displays.first(where: \.isBuiltin) ?? displays.first

        // Monitor sbagliato: rendo visibile la finestra e la sposto sul monitor giusto.
        for index in assignments.indices {
            let target = displays.first(where: { $0.key == assignments[index].saved.displayKey }) ?? fallback
            guard let target, assignments[index].tracked.displayKey != target.key else { continue }
            await reveal(assignments[index].tracked, displays: displays)
            let frame = targetFrame(for: assignments[index].saved, on: target, scene: scene)
            WindowManager.setFrame(assignments[index].tracked.live.element, to: frame)
            await Input.pause(0.2)
            assignments[index].tracked.displayKey = target.key
            assignments[index].tracked.desktop = SpacesManager.layouts(for: displays)[target.id]?.currentIndex.map { $0 + 1 }
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
            let assignment = assignments[index]
            guard let wanted = assignment.saved.desktop, let current = assignment.tracked.desktop, wanted != current,
                  let display = displays.first(where: { $0.key == assignment.tracked.displayKey }),
                  let layout = SpacesManager.layouts(for: displays)[display.id], wanted <= layout.count else { continue }
            guard await SpacesManager.switchDesktop(on: display, to: current - 1, displays: displays) else { continue }
            if await SpacesManager.moveWindow(assignment.tracked.live, on: display, to: wanted - 1, displays: displays) {
                assignments[index].tracked.desktop = wanted
            }
        }
    }

    /// Imposta posizione e dimensione, passando da una scrivania all'altra.
    private func placeFrames(_ assignments: [Assignment], scene: SavedScene, displays: [LiveDisplay]) async {
        let fallback = displays.first(where: \.isBuiltin) ?? displays.first
        let groups = Dictionary(grouping: assignments.indices) { index in
            "\(assignments[index].tracked.displayKey)#\(assignments[index].tracked.desktop ?? 0)"
        }
        for key in groups.keys.sorted() {
            guard let indices = groups[key], let first = indices.first else { continue }
            if manageSpaces { await reveal(assignments[first].tracked, displays: displays) }
            for index in indices {
                let assignment = assignments[index]
                guard let target = displays.first(where: { $0.key == assignment.saved.displayKey }) ?? fallback else { continue }
                WindowManager.setFrame(assignment.tracked.live.element, to: targetFrame(for: assignment.saved, on: target, scene: scene))
            }
            await Input.pause(0.2)
        }
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

    // MARK: Diagnostica

    func diagnostics() -> String {
        let displays = DisplayManager.activeDisplays()
        let layouts = SpacesManager.layouts(for: displays)
        var lines: [String] = []
        lines.append("Ormeggio \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Accessibilità: \(WindowManager.isTrusted(prompt: false) ? "concessa" : "NON concessa")")
        lines.append("Lettura scrivanie: \(SpacesManager.isAvailable ? "disponibile" : "non disponibile")")
        lines.append("Scorciatoie ctrl + frecce: \(Engine.desktopShortcutsEnabled ? "attive" : "DISATTIVATE")")
        lines.append("Impronta monitor: \(DisplayManager.fingerprint(displays))")
        for display in displays {
            var line = "• \(display.name) [\(display.key)]"
            if let mode = display.mode {
                line += " · \(mode.width)×\(mode.height) punti, \(mode.pixelWidth)×\(mode.pixelHeight) pixel"
            }
            if let layout = layouts[display.id] {
                line += " · \(layout.count) scrivanie"
                if let current = layout.currentIndex { line += ", visibile la \(current + 1)ª" }
                if let total = SpacesManager.totalSpaceCount(for: display, displays: displays), total > layout.count {
                    line += ", \(total - layout.count) app a tutto schermo"
                }
            }
            lines.append(line)
        }
        let windows = WindowManager.regularApps().flatMap { WindowManager.windows(of: $0) }
        let withID = windows.filter { $0.windowID != nil }.count
        lines.append("Finestre visibili: \(windows.count), con identificativo: \(withID)")
        if let sample = windows.first(where: { $0.windowID != nil }), let id = sample.windowID {
            lines.append("Scrivania di \"\(sample.appName)\": \(SpacesManager.spaceIDs(forWindow: id))")
        }
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
        let groups = Dictionary(grouping: tracked) { "\($0.displayKey) scrivania \($0.desktop.map { "\($0)" } ?? "tutte")" }
        return groups.keys.sorted().map { key in
            "[\(key): " + (groups[key] ?? []).map { $0.live.appName }.joined(separator: ", ") + "]"
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
    private static func folderIndex(for window: LiveWindow, in folders: [FinderWindowInfo]) -> Int? {
        guard !folders.isEmpty else { return nil }
        func gap(_ folder: FinderWindowInfo) -> CGFloat {
            abs(folder.frame.minX - window.frame.minX) + abs(folder.frame.minY - window.frame.minY)
                + abs(folder.frame.width - window.frame.width) + abs(folder.frame.height - window.frame.height)
        }
        let sameTitle = folders.indices.filter { FinderBridge.displayName(of: folders[$0].path) == window.title }
        if let best = sameTitle.min(by: { gap(folders[$0]) < gap(folders[$1]) }) { return best }
        guard let best = folders.indices.min(by: { gap(folders[$0]) < gap(folders[$1]) }) else { return nil }
        return gap(folders[best]) < 80 ? best : nil
    }
}
