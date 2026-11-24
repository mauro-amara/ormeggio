import AppKit
import ServiceManagement

/// Icona e menu nella barra dei menu, benvenuto, salvataggio e disinstallazione.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let store = SceneStore()
    private lazy var engine = Engine(store: store)
    private lazy var scenesWindow = ScenesWindowController(
        engine: engine,
        version: updater.currentVersion,
        onSave: { [weak self] in self?.saveScene() },
        onRepair: { [weak self] in self?.repairPermission(atLaunch: false) }
    )
    private let updater = Updater()
    private var trustTimer: Timer?
    private var installing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        engine.onStateChange = { [weak self] in self?.updateIcon() }
        engine.onActivity = { report in HUD.shared.show(report) }
        HUD.shared.sendDiagnostics = { [weak self] in self?.sendDiagnostics() }
        engine.askChromeProfiles = { [weak self] titles, profiles in
            self?.askChromeProfiles(titles: titles, profiles: profiles) ?? []
        }
        updateIcon()
        Log.write("Ormeggio avviato")

        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            showWelcome()
        } else if UserDefaults.standard.string(forKey: "updatedFrom") != nil {
            showUpdateCompleted()
        } else if !WindowManager.isTrusted(prompt: false) {
            repairPermissionAutomatically()
        }
        engine.start()
        watchPermission()
        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.onAvailable = { [weak self] info in self?.installAutomatically(info) }
        updater.start()
    }

    // MARK: Aggiornamenti

    /// Dopo un aggiornamento: lo dice nel riquadro e, se serve, ripara da solo il permesso di Accessibilità.
    private func showUpdateCompleted() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "updatedFrom")
        if let notes = defaults.string(forKey: "pendingUpdateNotes") {
            defaults.set(notes, forKey: "lastUpdateNotes")
            defaults.set(updater.currentVersion, forKey: "lastUpdateVersion")
            defaults.removeObject(forKey: "pendingUpdateNotes")
        }
        guard WindowManager.isTrusted(prompt: false) else {
            repairPermissionAutomatically()
            return
        }
        // Se la versione di prima non ha lasciato le novità, le leggo dalla pagina degli aggiornamenti.
        if defaults.string(forKey: "lastUpdateVersion") != updater.currentVersion {
            Task { @MainActor in
                if let info = await self.updater.latestPublished(), info.version == self.updater.currentVersion {
                    defaults.set(info.notes ?? "", forKey: "lastUpdateNotes")
                    defaults.set(info.version, forKey: "lastUpdateVersion")
                }
                self.showWhatsNew()
            }
        } else {
            showWhatsNew()
        }
    }

    /// Le novità dell'ultima versione installata, nel riquadro: una per riga.
    @objc private func showWhatsNew() {
        let defaults = UserDefaults.standard
        let version = defaults.string(forKey: "lastUpdateVersion") ?? updater.currentVersion
        let lines = (defaults.string(forKey: "lastUpdateNotes") ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let summary = lines.count > 1 ? lines[0] : nil
        let items = lines.count > 1 ? Array(lines.dropFirst()) : lines
        HUD.shared.show(ActivityReport(
            kind: .success,
            title: "Ormeggio aggiornato alla versione \(version)",
            subtitle: summary ?? (items.isEmpty ? "Le tue scene sono al loro posto" : "Ecco cosa cambia"),
            lines: items.map { ActivityReport.Line(text: $0) }
        ))
    }

    /// Installa da sola la versione nuova, appena Ormeggio non sta spostando finestre.
    private func installAutomatically(_ info: UpdateInfo) {
        guard !installing else { return }
        guard !engine.isWorking else {
            Task { @MainActor in
                await Input.pause(60)
                self.installAutomatically(info)
            }
            return
        }
        installing = true
        HUD.shared.show(ActivityReport(
            kind: .working,
            title: "Aggiorno Ormeggio alla versione \(info.version)…",
            subtitle: "Si chiude e si riapre da solo, le scene restano"
        ))
        Task { @MainActor in
            do {
                try await self.updater.install(info)
            } catch {
                self.installing = false
                Log.write("Aggiornamento non riuscito: \(error.localizedDescription)")
                HUD.shared.show(ActivityReport(
                    kind: .failure,
                    title: "Aggiornamento non riuscito",
                    subtitle: "Riprovo da solo tra un'ora",
                    lines: [.init(text: error.localizedDescription, warning: true)]
                ))
            }
        }
    }

    // MARK: Permesso di Accessibilità

    /// Toglie la voce di Accessibilità della versione precedente e la richiede per questa.
    /// Serve quando l'interruttore in Impostazioni risulta acceso ma macOS lo collega all'app vecchia.
    private func resetAndAskPermission() {
        if let bundleID = Bundle.main.bundleIdentifier {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleID]
            try? process.run()
            process.waitUntilExit()
            Log.write("Voce di Accessibilità azzerata (esito \(process.terminationStatus))")
        }
        if !WindowManager.isTrusted(prompt: true) {
            openAccessibilitySettings()
        }
        watchPermission()
    }

    @objc private func repairPermissionFromMenu() {
        repairPermissionAutomatically()
    }

    /// Toglie la voce vecchia di Accessibilità, la richiede e apre Impostazioni di Sistema.
    /// L'interruttore lo deve accendere la persona: macOS non lo lascia fare a nessuna app.
    private func repairPermissionAutomatically() {
        resetAndAskPermission()
        HUD.shared.show(ActivityReport(
            kind: .warning,
            title: "Accendi Ormeggio in Accessibilità",
            subtitle: "È l'unica cosa che macOS non lascia fare a un'app",
            lines: [.init(text: "Ho aperto Impostazioni di Sistema su Accessibilità. Accendi l'interruttore accanto a Ormeggio: il resto lo faccio io.", tone: .info)]
        ))
    }

    /// Per chi chiama ancora la vecchia versione con la domanda.
    private func repairPermission(atLaunch: Bool) {
        repairPermissionAutomatically()
    }

    /// Controlla il permesso ogni 2 secondi finché manca, così l'icona si aggiorna da sola.
    private func watchPermission() {
        guard trustTimer == nil, !WindowManager.isTrusted(prompt: false) else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.permissionTick() }
        }
    }

    private func permissionTick() {
        guard WindowManager.isTrusted(prompt: false) else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        Log.write("Permesso di Accessibilità concesso")
        engine.refreshState()
        updateIcon()
    }

    /// Indirizzo a cui arrivano le diagnostiche. Claude controlla quella casella ogni ora,
    /// corregge quello che non va e pubblica la versione nuova, che arriva a tutti da sola.
    static let feedbackAddress = "mauro.amara@sparkfabrik.com"

    /// Apre in Gmail una mail già pronta con la diagnostica: basta premere Invia.
    @objc private func sendDiagnostics() {
        let report = engine.supportReport(maxCharacters: 4500)
        let subject = "[Ormeggio] Diagnostica \(updater.currentVersion) da \(NSFullUserName())"
        let body = "Se vuoi, scrivi qui sopra cosa non è andato.\n\n" + report
        // Codifico tutto tranne lettere e numeri inglesi: "&", "=" e "+" nel testo romperebbero l'indirizzo.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let query = "view=cm&fs=1&to=\(encode(AppDelegate.feedbackAddress))&su=\(encode(subject))&body=\(encode(body))"
        guard let url = URL(string: "https://mail.google.com/mail/?" + query) else { return }
        NSWorkspace.shared.open(url)
        Log.write("Diagnostica preparata in Gmail (\(report.count) caratteri)")
        HUD.shared.show(ActivityReport(
            kind: .success,
            title: "Mail pronta in Gmail: premi Invia",
            subtitle: "Claude la riceve, corregge e manda la versione nuova a tutti"
        ))
    }

    @objc private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(engine.supportReport(), forType: .string)
        HUD.shared.show(ActivityReport(
            kind: .success,
            title: "Diagnostica copiata",
            subtitle: "Incollala nella chat con Claude (cmd V)"
        ))
    }

    @objc private func installUpdate() {
        guard let info = updater.available else { return }
        installAutomatically(info)
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            if await self.updater.check() == nil {
                HUD.shared.show(ActivityReport(
                    kind: .success,
                    title: "Hai già l'ultima versione",
                    subtitle: "Ormeggio \(self.updater.currentVersion)"
                ))
            }
        }
    }

    /// Riaprendo l'app dal Finder (o dal Launchpad) si apre la finestra delle scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scenesWindow.show()
        return false
    }

    // MARK: Benvenuto

    private func showWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeShown")
        let loginBox = NSButton(checkboxWithTitle: "Avvia Ormeggio quando accendi il Mac", target: nil, action: nil)
        loginBox.state = .on
        loginBox.frame = NSRect(x: 0, y: 0, width: 340, height: 22)

        let alert = NSAlert()
        alert.messageText = "Benvenuto in Ormeggio"
        alert.informativeText = """
        Ormeggio salva le tue scene di lavoro: app aperte, finestre su ogni monitor e scrivania, scala dei monitor. Le richiami con un clic dall'icona in alto, vicino all'orologio.

        Per spostare le finestre serve un permesso di macOS. Premi "Continua": si apre Impostazioni di Sistema, attiva Ormeggio nell'elenco Accessibilità e torna qui.
        """
        alert.accessoryView = loginBox
        alert.addButton(withTitle: "Continua")
        NSApp.activate()
        _ = alert.runModal()

        if loginBox.state == .on {
            do { try SMAppService.mainApp.register() } catch { Log.write("Avvio al login non attivato: \(error.localizedDescription)") }
        }
        if !WindowManager.isTrusted(prompt: true) {
            openAccessibilitySettings()
        }
        watchPermission()
        scenesWindow.show()
    }

    // MARK: Icona

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let tooltip: String
        switch engine.state {
        case .active(let name):
            tooltip = "Ormeggio: scena \(name)"
        case .idle:
            tooltip = "Ormeggio"
        case .working:
            tooltip = "Ormeggio sta sistemando le finestre: non toccare mouse e tastiera"
        case .needsPermission:
            tooltip = "Ormeggio: serve il permesso di Accessibilità"
        }
        if let image = Bundle.main.image(forResource: "MenuIcon") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
            button.title = engine.state == .needsPermission ? "!" : (updater.available != nil ? "•" : "")
            button.imagePosition = .imageLeft
        } else {
            button.image = nil
            button.title = "⚓︎"
        }
        // Mentre lavora l'ancora diventa grigia.
        button.appearsDisabled = engine.state == .working
        button.toolTip = tooltip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        engine.refreshState()
        let displays = DisplayManager.activeDisplays()
        let fingerprint = DisplayManager.fingerprint(displays)
        let active = engine.activeScene
        let trusted = WindowManager.isTrusted(prompt: false)

        if let update = updater.available {
            menu.addItem(commandItem("Aggiorna alla versione \(update.version)…", #selector(installUpdate), icon: "arrow.down.circle.fill"))
            menu.addItem(.separator())
        }

        // Stato
        if engine.isWorking {
            menu.addItem(infoItem("Sto sistemando le finestre…", icon: "hourglass", subtitle: "Non toccare mouse e tastiera"))
        } else if let active {
            menu.addItem(infoItem("Scena attiva: \(active.name)", icon: "checkmark.seal.fill"))
        } else {
            menu.addItem(infoItem("Nessuna scena attiva", icon: "moon.zzz"))
        }
        if !trusted {
            menu.addItem(commandItem("Ripara il permesso di Accessibilità…", #selector(repairPermissionFromMenu), icon: "exclamationmark.triangle.fill"))
        }

        // Scene: prima quelle di questi monitor
        let scenes = store.scenes.sorted { lhs, rhs in
            let lhsHere = lhs.fingerprint == fingerprint
            let rhsHere = rhs.fingerprint == fingerprint
            if lhsHere != rhsHere { return lhsHere }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Scene"))
        if scenes.isEmpty {
            menu.addItem(infoItem("Nessuna scena salvata", icon: "tray"))
        } else {
            for (offset, scene) in scenes.enumerated() {
                let key = offset < 9 ? "\(offset + 1)" : ""
                let item = commandItem(scene.name, #selector(recallScene(_:)), icon: SceneIcons.icon(for: scene), key: key)
                item.representedObject = scene.id.uuidString
                item.state = scene.id == active?.id ? .on : .off
                item.isEnabled = !engine.isWorking && trusted
                var details = [scene.fingerprint == fingerprint ? "Questi monitor" : "Altri monitor"]
                details.append("\(scene.windows.count) finestre")
                if scene.autoApply { details.append("automatica") }
                setSubtitle(item, details.joined(separator: " · "))
                menu.addItem(item)
            }
        }
        let saveItem = commandItem("Salva scena…", #selector(saveSceneFromMenu), icon: "plus.circle", key: "s")
        saveItem.isEnabled = !engine.isWorking
        menu.addItem(saveItem)
        menu.addItem(commandItem("Le tue scene…", #selector(showScenes), icon: "square.grid.2x2", key: "o"))

        // Monitor riconosciuti da macOS, con risoluzione e scrivanie
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: displays.count == 1 ? "Monitor collegato" : "Monitor collegati"))
        let layouts = SpacesManager.layouts(for: displays)
        for display in displays {
            var details: [String] = []
            if let mode = display.mode { details.append(mode.label) }
            if let layout = layouts[display.id] { details.append("\(layout.count) \(layout.count == 1 ? "scrivania" : "scrivanie")") }
            let item = infoItem(display.name, icon: display.isBuiltin ? "laptopcomputer" : "display",
                                subtitle: details.joined(separator: " · "))
            menu.addItem(item)
        }

        // Impostazioni
        menu.addItem(.separator())
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false
        let autoItem = commandItem("Richiamo automatico quando cambiano i monitor", #selector(toggleAutoApply), icon: "bolt.fill")
        autoItem.state = engine.autoApplyEnabled ? .on : .off
        settingsMenu.addItem(autoItem)
        let spacesItem = commandItem("Gestisci le scrivanie", #selector(toggleManageSpaces), icon: "square.on.square")
        spacesItem.state = engine.manageSpaces ? .on : .off
        settingsMenu.addItem(spacesItem)
        let loginItem = commandItem("Avvia quando accendi il Mac", #selector(toggleLogin), icon: "power")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(loginItem)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(commandItem("Invia la diagnostica a Claude…", #selector(sendDiagnostics), icon: "paperplane"))
        settingsMenu.addItem(commandItem("Copia la diagnostica", #selector(copyDiagnostics), icon: "doc.on.doc"))
        settingsMenu.addItem(commandItem("Diagnostica…", #selector(showDiagnostics), icon: "stethoscope"))
        settingsMenu.addItem(commandItem("Salva diagnostica per l'assistenza…", #selector(exportReport), icon: "doc.text"))
        settingsMenu.addItem(commandItem("Apri la cartella dei dati", #selector(openDataFolder), icon: "folder"))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(commandItem("Cerca aggiornamenti…", #selector(checkForUpdates), icon: "arrow.triangle.2.circlepath"))
        if UserDefaults.standard.string(forKey: "lastUpdateNotes")?.isEmpty == false {
            settingsMenu.addItem(commandItem("Novità dell'ultima versione", #selector(showWhatsNew), icon: "sparkles"))
        }
        settingsMenu.addItem(infoItem("Versione \(updater.currentVersion)", icon: "info.circle"))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(commandItem("Disinstalla Ormeggio…", #selector(uninstall), icon: "trash"))
        let settingsItem = NSMenuItem(title: "Impostazioni", action: nil, keyEquivalent: "")
        settingsItem.image = symbol("gearshape")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(commandItem("Esci da Ormeggio", #selector(quit), icon: "xmark.circle", key: "q"))
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func setSubtitle(_ item: NSMenuItem, _ subtitle: String) {
        guard !subtitle.isEmpty else { return }
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
        } else {
            item.title += "  ·  " + subtitle
        }
    }

    private func infoItem(_ title: String, icon: String? = nil, subtitle: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let icon { item.image = symbol(icon) }
        if let subtitle { setSubtitle(item, subtitle) }
        return item
    }

    private func commandItem(_ title: String, _ selector: Selector, icon: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        if let icon { item.image = symbol(icon) }
        return item
    }

    // MARK: Scene

    @objc private func recallScene(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        engine.recall(id: id)
    }

    @objc private func showScenes() {
        scenesWindow.show()
    }

    @objc private func saveSceneFromMenu() {
        saveScene()
    }

    private func saveScene() {
        guard WindowManager.isTrusted(prompt: false) else {
            repairPermission(atLaunch: false)
            return
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 340, height: 24))
        nameField.stringValue = engine.activeScene?.name ?? engine.suggestedName()
        nameField.placeholderString = "Per esempio: Ufficio 1"
        let autoBox = NSButton(checkboxWithTitle: "Richiamala da sola quando ritrovo questi monitor", target: nil, action: nil)
        autoBox.frame = NSRect(x: 0, y: 0, width: 340, height: 22)
        autoBox.state = (engine.activeScene?.autoApply ?? false) ? .on : .off
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        container.addSubview(nameField)
        container.addSubview(autoBox)

        let alert = NSAlert()
        alert.messageText = "Salva scena"
        let monitors = DisplayManager.activeDisplays().map(\.name).joined(separator: " + ")
        alert.informativeText = "Monitor riconosciuti: \(monitors).\n\nSalvo app aperte, finestre su ogni monitor e scrivania, scala dei monitor, cartelle del Finder, schede e zoom del browser. Se il nome esiste già, aggiorno quella scena.\n\nLavoro dietro le quinte: le scrivanie restano dove sono."
        alert.accessoryView = container
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Annulla")
        NSApp.activate()
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typed.isEmpty ? engine.suggestedName() : typed
        let autoApply = autoBox.state == .on
        NSApp.hide(nil)
        Task { @MainActor in
            await Input.pause(0.4)
            await self.engine.saveScene(name: name, autoApply: autoApply)
        }
    }

    /// Chiede il profilo delle finestre di Chrome che Ormeggio non ha riconosciuto.
    private func askChromeProfiles(titles: [String], profiles: [ChromeProfile]) -> [String?] {
        let rowHeight: CGFloat = 30
        let width: CGFloat = 420
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(titles.count)))
        var popups: [NSPopUpButton] = []
        for (offset, title) in titles.enumerated() {
            let y = CGFloat(titles.count - 1 - offset) * rowHeight
            let label = NSTextField(labelWithString: title.isEmpty ? "Finestra senza titolo" : title)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 0, y: y + 4, width: 240, height: 20)
            let popup = NSPopUpButton(frame: NSRect(x: 250, y: y, width: width - 250, height: 26), pullsDown: false)
            popup.addItems(withTitles: ["Non so"] + profiles.map(\.name))
            container.addSubview(label)
            container.addSubview(popup)
            popups.append(popup)
        }
        let alert = NSAlert()
        alert.messageText = "Di quale profilo Chrome sono queste finestre?"
        alert.informativeText = "Serve per riaprire ogni finestra nel profilo giusto, con le sue schede."
        alert.accessoryView = container
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        _ = alert.runModal()
        NSApp.hide(nil)
        return popups.map { popup in
            let index = popup.indexOfSelectedItem - 1
            return profiles.indices.contains(index) ? profiles[index].directory : nil
        }
    }

    // MARK: Impostazioni

    @objc private func toggleAutoApply() {
        engine.autoApplyEnabled.toggle()
    }

    @objc private func toggleManageSpaces() {
        engine.manageSpaces.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showMessage("Avvio all'accensione", "Non riesco a cambiare l'impostazione: \(error.localizedDescription)")
        }
    }

    @objc private func showDiagnostics() {
        let text = engine.diagnostics()
        let alert = NSAlert()
        alert.messageText = "Diagnostica di Ormeggio"
        alert.informativeText = text
        alert.addButton(withTitle: "Salva il file per l'assistenza…")
        alert.addButton(withTitle: "Copia negli appunti")
        alert.addButton(withTitle: "Chiudi")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            exportReport()
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
    }

    /// Salva un file di testo con diagnostica, scene e registro, da mandare all'assistenza.
    @objc private func exportReport() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let panel = NSSavePanel()
        panel.title = "Salva diagnostica"
        panel.message = "Il file contiene la diagnostica, l'elenco delle scene e il registro. Non contiene gli indirizzi delle schede."
        panel.nameFieldStringValue = "Ormeggio-diagnostica-\(formatter.string(from: Date())).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.supportReport().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showMessage("Diagnostica", "Non riesco a salvare il file: \(error.localizedDescription)")
        }
    }

    @objc private func openDataFolder() {
        _ = NSWorkspace.shared.open(Paths.folder)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            _ = NSWorkspace.shared.open(url)
        }
    }

    // MARK: Disinstallazione

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Disinstallare Ormeggio?"
        alert.informativeText = "Tolgo l'avvio all'accensione, cancello le scene salvate e i permessi, e sposto l'app nel Cestino."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disinstalla")
        alert.addButton(withTitle: "Annulla")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.unregister()
        try? FileManager.default.removeItem(at: Paths.folder)
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            for service in ["Accessibility", "AppleEvents"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", service, bundleID]
                try? process.run()
                process.waitUntilExit()
            }
        }
        let appURL = Bundle.main.bundleURL
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.recycle([appURL])
            } catch {
                self.showMessage("Disinstallazione", "Non riesco a spostare l'app nel Cestino. Trascinala tu da Applicazioni al Cestino.")
            }
            NSApp.terminate(nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        _ = alert.runModal()
    }
}
