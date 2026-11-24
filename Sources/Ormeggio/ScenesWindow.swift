import AppKit
import Combine
import SwiftUI

/// Finestra "Le tue scene": monitor collegati, scene salvate con anteprima, richiamo e modifica.
@MainActor
final class ScenesWindowController {
    private var window: NSWindow?
    private let model: ScenesModel

    init(engine: Engine, version: String,
         onSave: @escaping @MainActor () -> Void,
         onRepair: @escaping @MainActor () -> Void) {
        model = ScenesModel(engine: engine, version: version, onSave: onSave, onRepair: onRepair)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: ScenesView(model: model))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Ormeggio"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.isMovableByWindowBackground = true
            newWindow.setContentSize(NSSize(width: 860, height: 680))
            newWindow.contentMinSize = NSSize(width: 720, height: 540)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        model.reload()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Dati per l'anteprima

/// Una finestra disegnata nell'anteprima: posizione relativa al monitor e app.
struct WindowShape: Identifiable {
    let id: Int
    let frame: CGRect
    let bundleID: String
}

/// Un monitor disegnato nell'anteprima, nella sua posizione rispetto agli altri.
struct MonitorShape: Identifiable {
    let id: String
    let name: String
    let isBuiltin: Bool
    let bounds: CGRect
    let windows: [WindowShape]
    let desktops: Int
    let currentDesktop: Int
    let detail: String
}

/// Icone delle app, lette una volta sola.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = image
        return image
    }
}

/// Icone che si possono dare a una scena.
enum SceneIcons {
    static let choices = [
        "building.2.fill", "house.fill", "laptopcomputer", "desktopcomputer", "display.2", "briefcase.fill",
        "person.2.fill", "video.fill", "cup.and.saucer.fill", "sofa.fill", "airplane", "tram.fill",
        "graduationcap.fill", "books.vertical.fill", "chart.bar.fill", "terminal.fill", "paintpalette.fill", "music.note",
        "gamecontroller.fill", "leaf.fill", "sun.max.fill", "moon.fill", "star.fill", "heart.fill"
    ]

    /// L'icona scelta, o una indovinata dal nome e dai monitor.
    static func icon(for scene: SavedScene) -> String {
        if let icon = scene.icon, !icon.isEmpty { return icon }
        let name = scene.name.lowercased()
        if ["uffic", "office", "lavoro", "spark", "work"].contains(where: { name.contains($0) }) { return "building.2.fill" }
        if ["casa", "home", "mamma", "satta"].contains(where: { name.contains($0) }) { return "house.fill" }
        if !scene.displays.isEmpty, scene.displays.allSatisfy(\.isBuiltin) { return "laptopcomputer" }
        return "display.2"
    }
}

// MARK: - Modello

@MainActor
final class ScenesModel: ObservableObject {
    let engine: Engine
    let version: String
    private let onSave: @MainActor () -> Void
    private let onRepair: @MainActor () -> Void

    @Published var scenes: [SavedScene] = []
    @Published var activeID: UUID?
    @Published var fingerprint: String = ""
    @Published var current: [MonitorShape] = []
    @Published var trusted = true
    @Published var working = false

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(engine: Engine, version: String,
         onSave: @escaping @MainActor () -> Void,
         onRepair: @escaping @MainActor () -> Void) {
        self.engine = engine
        self.version = version
        self.onSave = onSave
        self.onRepair = onRepair
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: SceneStore.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reload() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.reload() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        reload()
    }

    func reload() {
        scenes = engine.store.scenes
        activeID = engine.activeSceneID
        let displays = DisplayManager.activeDisplays()
        fingerprint = DisplayManager.fingerprint(displays)
        let layouts = SpacesManager.layouts(for: displays)
        current = displays.map { display in
            let layout = layouts[display.id]
            let count = layout?.count ?? 1
            var detail = display.mode?.label ?? ""
            if layout != nil {
                detail += (detail.isEmpty ? "" : " · ") + "\(count) \(count == 1 ? "scrivania" : "scrivanie")"
            }
            return MonitorShape(
                id: display.key, name: display.name, isBuiltin: display.isBuiltin, bounds: display.bounds,
                windows: [], desktops: count, currentDesktop: (layout?.currentIndex ?? 0) + 1, detail: detail
            )
        }
        tick()
    }

    /// Ogni 2 secondi: permesso e stato del lavoro, così la finestra resta aggiornata.
    func tick() {
        let isTrusted = WindowManager.isTrusted(prompt: false)
        if isTrusted != trusted { trusted = isTrusted }
        if engine.isWorking != working { working = engine.isWorking }
        if engine.activeSceneID != activeID { activeID = engine.activeSceneID }
    }

    /// Prima le scene di questi monitor, poi le altre, in ordine di nome.
    var sortedScenes: [SavedScene] {
        scenes.sorted { lhs, rhs in
            let lhsHere = lhs.fingerprint == fingerprint
            let rhsHere = rhs.fingerprint == fingerprint
            if lhsHere != rhsHere { return lhsHere }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// La scena pensata per i monitor collegati ora, se c'è.
    var suggested: SavedScene? {
        let here = scenes.filter { $0.fingerprint == fingerprint }
        return here.first(where: \.autoApply) ?? here.first(where: { $0.id == activeID }) ?? here.first
    }

    /// Anteprima della scena: i monitor e le finestre della scrivania che era visibile.
    func shapes(for scene: SavedScene) -> [MonitorShape] {
        scene.displays.map { display in
            let visible = display.currentDesktop ?? 1
            let windows = scene.windows.enumerated().compactMap { item -> WindowShape? in
                let window = item.element
                guard window.displayKey == display.key, window.minimized != true else { return nil }
                if let desktop = window.desktop, desktop != visible { return nil }
                return WindowShape(id: item.offset, frame: window.frame.cgRect, bundleID: window.bundleID)
            }
            // Le finestre grandi sotto, le piccole sopra.
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            return MonitorShape(
                id: display.key, name: display.name, isBuiltin: display.isBuiltin, bounds: display.bounds.cgRect,
                windows: windows, desktops: display.spaceCount ?? 1, currentDesktop: visible,
                detail: display.mode?.label ?? ""
            )
        }
    }

    func appCount(_ scene: SavedScene) -> Int {
        Set(scene.windows.map(\.bundleID)).count
    }

    func desktopCount(_ scene: SavedScene) -> Int {
        scene.displays.compactMap(\.spaceCount).reduce(0, +)
    }

    func savedWhen(_ scene: SavedScene) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .full
        return "salvata " + formatter.localizedString(for: scene.savedAt, relativeTo: Date())
    }

    // MARK: Azioni

    func recall(_ scene: SavedScene) {
        engine.recall(id: scene.id)
        NSApp.hide(nil)
    }

    func save() { onSave() }

    func repair() { onRepair() }

    func setAuto(_ scene: SavedScene, _ enabled: Bool) {
        engine.setAutoApply(id: scene.id, enabled)
    }

    func setIcon(_ scene: SavedScene, _ icon: String) {
        engine.setIcon(id: scene.id, icon)
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
        alert.messageText = "Eliminare la scena “\(scene.name)”?"
        alert.informativeText = "Le finestre restano come sono: cancello solo la scena salvata."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Elimina")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.deleteScene(id: scene.id)
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
        alert.messageText = "Zoom delle app in “\(scene.name)”"
        guard !apps.isEmpty else {
            alert.informativeText = "In questa scena non ci sono app di cui scegliere lo zoom. Lo zoom di Chrome Ormeggio lo salva da solo, sito per sito."
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            return
        }
        let rowHeight: CGFloat = 32
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: rowHeight * CGFloat(apps.count)))
        var popups: [NSPopUpButton] = []
        for (offset, app) in apps.enumerated() {
            let y = CGFloat(apps.count - 1 - offset) * rowHeight
            let icon = NSImageView(frame: NSRect(x: 0, y: y + 3, width: 22, height: 22))
            icon.image = AppIcons.icon(for: app.bundleID)
            icon.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: app.name)
            label.frame = NSRect(x: 30, y: y + 5, width: 180, height: 20)
            label.lineBreakMode = .byTruncatingTail
            let popup = NSPopUpButton(frame: NSRect(x: 220, y: y + 1, width: 180, height: 26), pullsDown: false)
            popup.addItems(withTitles: options.map { $0.title })
            let current = scene.appZoom?[app.bundleID]
            popup.selectItem(at: options.firstIndex(where: { $0.steps == current }) ?? 0)
            container.addSubview(icon)
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
}

// MARK: - Finestra

struct ScenesView: View {
    @ObservedObject var model: ScenesModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    CurrentMonitorsPanel(model: model)
                    scenesSection
                }
                .padding(.horizontal, 26)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 540)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Ormeggio")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Ogni finestra al suo posto, con un clic.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.save()
            } label: {
                Label("Salva scena", systemImage: "plus.circle.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.working)
            .help("Salva come sono adesso app, finestre, scrivanie e zoom")
        }
    }

    @ViewBuilder
    private var scenesSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Le tue scene")
                .font(.title3.weight(.semibold))
            if !model.scenes.isEmpty {
                Text("\(model.scenes.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            Spacer()
        }
        if model.scenes.isEmpty {
            EmptyScenesView(model: model)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 520), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(model.sortedScenes) { scene in
                    SceneCard(scene: scene, isActive: scene.id == model.activeID, model: model)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.working {
                ProgressView().controlSize(.small)
                Text("Sto sistemando le finestre: non toccare mouse e tastiera")
            } else if model.trusted {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                Text("Permesso di Accessibilità attivo")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Manca il permesso di Accessibilità: senza, Ormeggio non vede le finestre")
                Button("Ripara") { model.repair() }
                    .controlSize(.small)
            }
            Spacer()
            Text("Versione \(model.version)")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// I monitor collegati adesso, con la scena giusta per loro.
private struct CurrentMonitorsPanel: View {
    @ObservedObject var model: ScenesModel

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            MonitorLayoutView(monitors: model.current)
                .frame(width: 210, height: 92)
            VStack(alignment: .leading, spacing: 8) {
                Text("COLLEGATI ORA")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.current) { monitor in
                    HStack(spacing: 9) {
                        Image(systemName: monitor.isBuiltin ? "laptopcomputer" : "display")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(monitor.name).font(.callout.weight(.medium))
                            if !monitor.detail.isEmpty {
                                Text(monitor.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            if let scene = model.suggested {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Scena per questi monitor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.recall(scene)
                    } label: {
                        Label(scene.name, systemImage: SceneIcons.icon(for: scene))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.working)
                    .help("Richiama “\(scene.name)”")
                }
            }
        }
        .padding(18)
        .cardBackground()
    }
}

private struct EmptyScenesView: View {
    @ObservedObject var model: ScenesModel

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                StepView(number: 1, symbol: "macwindow.on.rectangle", title: "Sistema il Mac",
                         text: "Apri le app e mettile dove vuoi, su monitor e scrivanie. Regola lo zoom.")
                StepView(number: 2, symbol: "square.and.arrow.down", title: "Salva la scena",
                         text: "Dagli un nome: Ufficio, Casa, Mac da solo.")
                StepView(number: 3, symbol: "play.circle", title: "Richiamala",
                         text: "Con un clic dall'ancora in alto, o da sola quando ricolleghi i monitor.")
            }
            Button {
                model.save()
            } label: {
                Label("Salva la prima scena", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cardBackground()
    }
}

private struct StepView: View {
    let number: Int
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
            }
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Scheda di una scena

private struct SceneCard: View {
    let scene: SavedScene
    let isActive: Bool
    @ObservedObject var model: ScenesModel
    @State private var hovering = false
    @State private var pickingIcon = false

    var body: some View {
        let here = scene.fingerprint == model.fingerprint
        let desktops = model.desktopCount(scene)
        VStack(alignment: .leading, spacing: 12) {
            MonitorLayoutView(monitors: model.shapes(for: scene))
                .frame(height: 118)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )

            HStack(alignment: .center, spacing: 11) {
                Button {
                    pickingIcon = true
                } label: {
                    Image(systemName: SceneIcons.icon(for: scene))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Cambia icona")
                .popover(isPresented: $pickingIcon, arrowEdge: .bottom) {
                    IconPicker(selected: SceneIcons.icon(for: scene)) { symbol in
                        model.setIcon(scene, symbol)
                        pickingIcon = false
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if isActive {
                            Badge(text: "In uso", symbol: "checkmark.circle.fill", color: .green)
                        }
                        if here {
                            Badge(text: "Questi monitor", symbol: "display", color: .accentColor)
                        } else {
                            Badge(text: "Altri monitor", symbol: "display.trianglebadge.exclamationmark", color: .orange)
                        }
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button { model.editZoom(scene) } label: { Label("Zoom delle app…", systemImage: "plus.magnifyingglass") }
                    Button { pickingIcon = true } label: { Label("Cambia icona…", systemImage: "face.smiling") }
                    Button { model.rename(scene) } label: { Label("Rinomina…", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { model.delete(scene) } label: { Label("Elimina…", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Altre azioni")
            }

            HStack(spacing: 14) {
                Label("\(scene.windows.count) finestre", systemImage: "macwindow")
                Label("\(model.appCount(scene)) app", systemImage: "square.grid.2x2")
                if desktops > 0 {
                    Label("\(desktops) scrivanie", systemImage: "square.on.square")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(model.savedWhen(scene))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { scene.autoApply }, set: { model.setAuto(scene, $0) })) {
                    Label("Automatica", systemImage: "bolt.fill")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Richiama questa scena da sola quando ricolleghi questi monitor")
                Spacer()
                Button {
                    model.recall(scene)
                } label: {
                    Label("Richiama", systemImage: "play.fill")
                        .padding(.horizontal, 2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.working || !model.trusted)
            }
        }
        .padding(16)
        .cardBackground(highlight: isActive, hovering: hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct Badge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct IconPicker: View {
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scegli un'icona")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6), spacing: 6) {
                ForEach(SceneIcons.choices, id: \.self) { symbol in
                    Button {
                        onPick(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(symbol == selected ? Color.accentColor : Color.primary)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(symbol == selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Anteprima dei monitor

/// Disegna i monitor nella loro posizione reciproca, come in Impostazioni di Sistema, con le finestre dentro.
struct MonitorLayoutView: View {
    let monitors: [MonitorShape]

    struct Placed: Identifiable {
        let monitor: MonitorShape
        let rect: CGRect
        let scale: CGFloat
        var id: String { monitor.id }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Self.place(monitors, in: proxy.size)) { placed in
                    MonitorTile(monitor: placed.monitor, size: placed.rect.size, scale: placed.scale)
                        .frame(width: placed.rect.width, height: placed.rect.height)
                        .offset(x: placed.rect.minX, y: placed.rect.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    static func place(_ monitors: [MonitorShape], in size: CGSize) -> [Placed] {
        guard let first = monitors.first, size.width > 0, size.height > 0 else { return [] }
        var union = first.bounds
        for monitor in monitors.dropFirst() { union = union.union(monitor.bounds) }
        guard union.width > 0, union.height > 0 else { return [] }
        let scale = min(size.width / union.width, size.height / union.height)
        let originX = (size.width - union.width * scale) / 2
        let originY = (size.height - union.height * scale) / 2
        return monitors.map { monitor in
            let rect = CGRect(
                x: originX + (monitor.bounds.minX - union.minX) * scale,
                y: originY + (monitor.bounds.minY - union.minY) * scale,
                width: monitor.bounds.width * scale,
                height: monitor.bounds.height * scale
            ).insetBy(dx: 2, dy: 2)
            return Placed(monitor: monitor, rect: rect, scale: rect.width / max(monitor.bounds.width, 1))
        }
    }
}

private struct MonitorTile: View {
    let monitor: MonitorShape
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.34), Color.accentColor.opacity(0.14)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            ForEach(monitor.windows) { window in
                let width = min(max(window.frame.width * scale, 6), size.width)
                let height = min(max(window.frame.height * scale, 5), size.height)
                WindowTile(bundleID: window.bundleID, side: min(width, height))
                    .frame(width: width, height: height)
                    .offset(x: max(0, window.frame.minX * scale), y: max(0, window.frame.minY * scale))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
        .overlay(alignment: .bottom) {
            if monitor.desktops > 1, size.height > 28 {
                HStack(spacing: 3) {
                    ForEach(1...min(monitor.desktops, 9), id: \.self) { index in
                        Circle()
                            .fill(index == monitor.currentDesktop ? Color.primary.opacity(0.8) : Color.primary.opacity(0.25))
                            .frame(width: 4, height: 4)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.7)))
                .padding(.bottom, 3)
            }
        }
        .help(monitor.name + (monitor.detail.isEmpty ? "" : " · \(monitor.detail)"))
    }
}

private struct WindowTile: View {
    let bundleID: String
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
            .overlay {
                if side >= 10 {
                    Image(nsImage: AppIcons.icon(for: bundleID))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: min(side * 0.6, 26), height: min(side * 0.6, 26))
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
    }
}

// MARK: - Stile delle schede

private extension View {
    func cardBackground(highlight: Bool = false, hovering: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return self
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                shape.strokeBorder(
                    highlight ? Color.accentColor : Color.primary.opacity(hovering ? 0.18 : 0.08),
                    lineWidth: highlight ? 2 : 1
                )
            )
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 10 : 4, y: 2)
    }
}
