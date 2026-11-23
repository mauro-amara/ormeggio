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
                Text(scene.name)
                    .font(.headline)
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
