import AppKit
import ServiceManagement

/// Icona e menu nella barra dei menu, benvenuto, salvataggio e disinstallazione.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let store = SceneStore()
    private lazy var engine = Engine(store: store)
    private lazy var scenesWindow = ScenesWindowController(engine: engine) { [weak self] in
        self?.saveScene()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        engine.onStateChange = { [weak self] in self?.updateIcon() }
        engine.askChromeProfiles = { [weak self] titles, profiles in
            self?.askChromeProfiles(titles: titles, profiles: profiles) ?? []
        }
        updateIcon()
        Log.write("Ormeggio avviato")

        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            showWelcome()
        } else if !WindowManager.isTrusted(prompt: false) {
            _ = WindowManager.isTrusted(prompt: true)
        }
        engine.start()
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
        scenesWindow.show()
    }

    // MARK: Icona

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let tooltip: String
        switch engine.state {
        case .active(let name):
            symbol = "macwindow.on.rectangle"
            tooltip = "Ormeggio: scena \(name)"
        case .idle:
            symbol = "macwindow"
            tooltip = "Ormeggio"
        case .working:
            symbol = "arrow.triangle.2.circlepath"
            tooltip = "Ormeggio sta sistemando le finestre: non toccare mouse e tastiera"
        case .needsPermission:
            symbol = "exclamationmark.triangle"
            tooltip = "Ormeggio: serve il permesso di Accessibilità"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ormeggio") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = "⚓︎"
        }
        button.toolTip = tooltip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        engine.refreshState()
        let displays = DisplayManager.activeDisplays()
        let fingerprint = DisplayManager.fingerprint(displays)
        let active = engine.activeScene

        if engine.isWorking {
            menu.addItem(infoItem("Sto sistemando le finestre…"))
            menu.addItem(infoItem("Non toccare mouse e tastiera per qualche secondo"))
            menu.addItem(.separator())
        } else {
            menu.addItem(infoItem(active.map { "Scena attiva: \($0.name)" } ?? "Nessuna scena attiva"))
        }
        if !WindowManager.isTrusted(prompt: false) {
            menu.addItem(commandItem("⚠︎ Attiva Ormeggio in Accessibilità…", #selector(openAccessibilitySettings)))
        }

        let scenes = store.scenes.sorted { lhs, rhs in
            let lhsHere = lhs.fingerprint == fingerprint
            let rhsHere = rhs.fingerprint == fingerprint
            if lhsHere != rhsHere { return lhsHere }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        menu.addItem(.separator())
        if scenes.isEmpty {
            menu.addItem(infoItem("Nessuna scena salvata"))
        } else {
            menu.addItem(infoItem("Richiama una scena"))
            for scene in scenes {
                var title = scene.name
                if scene.fingerprint != fingerprint { title += "  (altri monitor)" }
                let item = commandItem(title, #selector(recallScene(_:)))
                item.representedObject = scene.id.uuidString
                item.state = scene.id == active?.id ? .on : .off
                item.isEnabled = !engine.isWorking
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let saveItem = commandItem("Salva scena…", #selector(saveSceneFromMenu))
        saveItem.isEnabled = !engine.isWorking
        menu.addItem(saveItem)
        menu.addItem(commandItem("Le tue scene…", #selector(showScenes)))

        menu.addItem(.separator())
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false
        let autoItem = commandItem("Richiama da sola la scena quando cambiano i monitor", #selector(toggleAutoApply))
        autoItem.state = engine.autoApplyEnabled ? .on : .off
        settingsMenu.addItem(autoItem)
        let spacesItem = commandItem("Gestisci le scrivanie", #selector(toggleManageSpaces))
        spacesItem.state = engine.manageSpaces ? .on : .off
        settingsMenu.addItem(spacesItem)
        let loginItem = commandItem("Avvia quando accendi il Mac", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsMenu.addItem(loginItem)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(commandItem("Diagnostica…", #selector(showDiagnostics)))
        settingsMenu.addItem(commandItem("Apri la cartella dei dati", #selector(openDataFolder)))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(commandItem("Disinstalla Ormeggio…", #selector(uninstall)))
        let settingsItem = NSMenuItem(title: "Impostazioni", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(commandItem("Esci da Ormeggio", #selector(quit)))
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func commandItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
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
            showMessage("Manca un permesso", "Per salvare le finestre Ormeggio deve essere attivo in Impostazioni di Sistema > Privacy e sicurezza > Accessibilità.")
            openAccessibilitySettings()
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
        alert.informativeText = "Salvo app aperte, finestre su ogni monitor e scrivania, scala dei monitor, cartelle del Finder e schede del browser. Se il nome esiste già, aggiorno quella scena.\n\nPer vedere tutte le finestre passo da ogni scrivania: per qualche secondo non toccare mouse e tastiera."
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
        alert.addButton(withTitle: "Copia negli appunti")
        alert.addButton(withTitle: "Chiudi")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(text, forType: .string)
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
