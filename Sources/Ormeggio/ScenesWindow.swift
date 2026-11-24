import AppKit
import SwiftUI

/// Finestra "Le tue scene": elenco, richiamo, rinomina, richiamo automatico, eliminazione.
@MainActor
final class ScenesWindowController {
    private var window: NSWindow?
    private let model: ScenesModel

    init(engine: Engine, onSaveRequested: @escaping @MainActor () -> Void) {
        model = ScenesModel(engine: engine, onSaveRequested: onSaveRequested)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ScenesView(model: model))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Ormeggio"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 600, height: 420))
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        model.reload()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ScenesModel: ObservableObject {
    let engine: Engine
    let onSaveRequested: @MainActor () -> Void
    @Published var scenes: [SavedScene] = []
    @Published var activeID: UUID?
    @Published var monitors: String = ""
    @Published var fingerprint: String = ""
    private var observer: NSObjectProtocol?

    init(engine: Engine, onSaveRequested: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.onSaveRequested = onSaveRequested
        observer = NotificationCenter.default.addObserver(forName: SceneStore.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reload() }
        }
        reload()
    }

    func reload() {
        scenes = engine.store.scenes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeID = engine.activeSceneID
        let displays = DisplayManager.activeDisplays()
        monitors = displays.map { display in
            display.mode.map { "\(display.name) (\($0.label))" } ?? display.name
        }.joined(separator: " + ")
        fingerprint = DisplayManager.fingerprint(displays)
    }

    func recall(_ scene: SavedScene) {
        engine.recall(id: scene.id)
        NSApp.hide(nil)
    }

    func setAuto(_ scene: SavedScene, _ enabled: Bool) {
        engine.setAutoApply(id: scene.id, enabled)
    }

    func rename(_ scene: SavedScene) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = scene.name
        let alert = NSAlert()
        alert.messageText = "Rinomina la scena"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rinomina")
        alert.addButton(withTitle: "Annulla")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.renameScene(id: scene.id, to: field.stringValue)
    }

    func delete(_ scene: SavedScene) {
        let alert = NSAlert()
        alert.messageText = "Eliminare la scena \"\(scene.name)\"?"
        alert.informativeText = "Le finestre restano come sono: cancello solo la scena salvata."
        alert.addButton(withTitle: "Elimina")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.deleteScene(id: scene.id)
    }

    func saveNew() {
        onSaveRequested()
    }

    /// Sceglie lo zoom di ogni app della scena (Chrome escluso: il suo zoom si salva da solo).
    func editZoom(_ scene: SavedScene) {
        let excluded: Set<String> = [BrowserBridge.chromeID, FinderBridge.bundleID, Engine.settingsID]
        var seen = Set<String>()
        let apps = scene.windows.compactMap { window -> (bundleID: String, name: String)? in
            guard !excluded.contains(window.bundleID), seen.insert(window.bundleID).inserted else { return nil }
            return (window.bundleID, window.appName)
        }
        let options: [(title: String, steps: Int?)] = [
            ("Non toccare", nil), ("Normale (100%)", 0),
            ("+1 scatto", 1), ("+2 scatti", 2), ("+3 scatti", 3), ("+4 scatti", 4),
            ("−1 scatto", -1), ("−2 scatti", -2)
        ]
        let alert = NSAlert()
        alert.messageText = "Zoom delle app in \"\(scene.name)\""
        guard !apps.isEmpty else {
            alert.informativeText = "In questa scena non ci sono app di cui scegliere lo zoom. Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito."
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return
        }
        let rowHeight: CGFloat = 30
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: rowHeight * CGFloat(apps.count)))
        var popups: [NSPopUpButton] = []
        for (offset, app) in apps.enumerated() {
            let y = CGFloat(apps.count - 1 - offset) * rowHeight
            let label = NSTextField(labelWithString: app.name)
            label.frame = NSRect(x: 0, y: y + 4, width: 190, height: 20)
            let popup = NSPopUpButton(frame: NSRect(x: 200, y: y, width: 180, height: 26), pullsDown: false)
            popup.addItems(withTitles: options.map { $0.title })
            let current = scene.appZoom?[app.bundleID]
            popup.selectItem(at: options.firstIndex(where: { $0.steps == current }) ?? 0)
            container.addSubview(label)
            container.addSubview(popup)
            popups.append(popup)
        }
        alert.informativeText = "Quando richiami la scena, Ormeggio porta ogni app allo zoom che scegli qui, come se premessi cmd + o cmd -. Lo zoom di Chrome lo salva da solo, sito per sito."
        alert.accessoryView = container
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var values: [String: Int] = [:]
        for (offset, popup) in popups.enumerated() {
            let index = popup.indexOfSelectedItem
            if options.indices.contains(index), let steps = options[index].steps {
                values[apps[offset].bundleID] = steps
            }
        }
        engine.setAppZoom(id: scene.id, values)
    }

    func summary(of scene: SavedScene) -> String {
        let monitors = scene.displays.map(\.name).joined(separator: " + ")
        let desktops = scene.displays.compactMap(\.spaceCount).reduce(0, +)
        var parts = [monitors, "\(scene.windows.count) finestre"]
        if desktops > 0 { parts.append("\(desktops) scrivanie") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        parts.append("salvata il \(formatter.string(from: scene.savedAt))")
        return parts.joined(separator: " · ")
    }
}

struct ScenesView: View {
    @ObservedObject var model: ScenesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Le tue scene")
                        .font(.title2.bold())
                    Text("Sistema il Mac come ti serve, salva la scena e richiamala quando vuoi.")
                        .foregroundStyle(.secondary)
                    Label("Ora: \(model.monitors)", systemImage: "display.2")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Salva scena…") { model.saveNew() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .controlSize(.large)
            }

            if model.scenes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Nessuna scena salvata")
                        .font(.headline)
                    Text("Apri le app, mettile dove vuoi sui monitor e nelle scrivanie, poi premi \"Salva scena…\".")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.scenes) { scene in
                        SceneRow(scene: scene, isActive: scene.id == model.activeID, model: model)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct SceneRow: View {
    let scene: SavedScene
    let isActive: Bool
    @ObservedObject var model: ScenesModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(scene.name)
                        .font(.headline)
                    if scene.fingerprint == model.fingerprint {
                        Text("questi monitor")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(model.summary(of: scene))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Toggle("Richiamala da sola quando ritrovo questi monitor", isOn: Binding(
                    get: { scene.autoApply },
                    set: { model.setAuto(scene, $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            Spacer()
            Button("Richiama") { model.recall(scene) }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("Zoom delle app…") { model.editZoom(scene) }
                Button("Rinomina…") { model.rename(scene) }
                Button("Elimina…", role: .destructive) { model.delete(scene) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
        .padding(.vertical, 6)
    }
}
