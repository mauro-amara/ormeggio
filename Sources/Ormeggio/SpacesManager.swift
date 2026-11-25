import AppKit
import CoreGraphics

/// Scrivanie di un monitor, nell'ordine di Mission Control.
struct DesktopLayout {
    let spaceIDs: [Int]
    /// Indice (da 0) della scrivania visibile.
    let currentIndex: Int?

    var count: Int { spaceIDs.count }
}

/// Scrivanie (Spaces) di macOS.
///
/// Apple non offre API pubbliche per le scrivanie. La lettura usa funzioni private caricate
/// a runtime: se macOS le cambia, Ormeggio continua a funzionare senza scrivanie.
/// Per cambiare scrivania e spostarci le finestre Ormeggio simula ciò che farebbe l'utente:
/// ctrl + freccia, e il trascinamento della finestra mentre cambia scrivania.
/// Per aggiungere e togliere scrivanie usa Mission Control tramite Accessibilità.
@MainActor
enum SpacesManager {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CreateUUIDFn = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
    private typealias SpaceSetCompatIDFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SetWindowListWorkspaceFn = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32

    /// Spostamento istantaneo tra scrivanie: nil finché non l'ho provato, poi se funziona su questo Mac.
    private(set) static var instantMovesWork: Bool?
    /// Il trascinamento tra scrivanie non ha funzionato in questo richiamo: non lo riprovo con le altre finestre.
    static var dragFailed = false

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let handle = skyLight, let pointer = dlsym(handle, name) { return pointer }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static func connection() -> Int32? {
        guard let pointer = symbol("CGSMainConnectionID") else { return nil }
        return unsafeBitCast(pointer, to: MainConnectionFn.self)()
    }

    static var isAvailable: Bool {
        symbol("CGSMainConnectionID") != nil && symbol("CGSCopyManagedDisplaySpaces") != nil
    }

    // MARK: Lettura

    /// Scrivanie normali (escluse le app a tutto schermo) per ogni monitor.
    static func layouts(for displays: [LiveDisplay]) -> [CGDirectDisplayID: DesktopLayout] {
        guard let connection = connection(), let copyPointer = symbol("CGSCopyManagedDisplaySpaces") else { return [:] }
        guard let array = unsafeBitCast(copyPointer, to: CopyManagedDisplaySpacesFn.self)(connection)?.takeRetainedValue(),
              let entries = array as? [[String: Any]] else { return [:] }

        var uuidToDisplay: [String: CGDirectDisplayID] = [:]
        for display in displays {
            if let uuid = uuid(for: display.id) { uuidToDisplay[uuid.uppercased()] = display.id }
        }

        var result: [CGDirectDisplayID: DesktopLayout] = [:]
        for entry in entries {
            let identifier = (entry["Display Identifier"] as? String ?? "").uppercased()
            let displayID: CGDirectDisplayID
            if identifier == "MAIN" {
                displayID = CGMainDisplayID()
            } else if let id = uuidToDisplay[identifier] {
                displayID = id
            } else {
                continue
            }
            let userSpaces = (entry["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int ?? 0) == 0 }
            let ids = userSpaces.compactMap { $0["ManagedSpaceID"] as? Int }
            let currentID = (entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            result[displayID] = DesktopLayout(spaceIDs: ids, currentIndex: ids.firstIndex { $0 == currentID })
        }
        return result
    }

    /// Numero di tutte le scrivanie di un monitor, comprese quelle delle app a tutto schermo.
    static func totalSpaceCount(for display: LiveDisplay, displays: [LiveDisplay]) -> Int? {
        guard let connection = connection(), let copyPointer = symbol("CGSCopyManagedDisplaySpaces"),
              let array = unsafeBitCast(copyPointer, to: CopyManagedDisplaySpacesFn.self)(connection)?.takeRetainedValue(),
              let entries = array as? [[String: Any]] else { return nil }
        let wantedUUID = uuid(for: display.id)?.uppercased()
        for entry in entries {
            let identifier = (entry["Display Identifier"] as? String ?? "").uppercased()
            let matches = identifier == wantedUUID || (identifier == "MAIN" && display.id == CGMainDisplayID())
            if matches { return (entry["Spaces"] as? [[String: Any]])?.count }
        }
        return nil
    }

    /// Scrivanie su cui si trova una finestra (più di una se è "su tutte le scrivanie").
    static func spaceIDs(forWindow windowID: CGWindowID) -> [Int] {
        guard let connection = connection(), let pointer = symbol("CGSCopySpacesForWindows") else { return [] }
        let input = [NSNumber(value: windowID)] as CFArray
        guard let output = unsafeBitCast(pointer, to: CopySpacesForWindowsFn.self)(connection, 7, input)?.takeRetainedValue(),
              let numbers = output as? [NSNumber] else { return [] }
        return numbers.map(\.intValue)
    }

    private static func uuid(for display: CGDirectDisplayID) -> String? {
        guard let pointer = symbol("CGDisplayCreateUUIDFromDisplayID"),
              let uuid = unsafeBitCast(pointer, to: CreateUUIDFn.self)(display)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return text as String
    }

    // MARK: Spostarsi tra le scrivanie

    /// Manda una finestra su un'altra scrivania senza mostrarla e senza trascinarla, con funzioni private
    /// di macOS: do un numero provvisorio alla scrivania di arrivo, ci mando la finestra, tolgo il numero.
    /// Controlla che la finestra sia arrivata. Se la prima volta non funziona, su questo Mac non lo riprova.
    static func sendWindow(_ windowID: CGWindowID, toSpace spaceID: Int) async -> Bool {
        if instantMovesWork == false { return false }
        if spaceIDs(forWindow: windowID).contains(spaceID) { return true }
        guard let connection = connection(),
              let compatPointer = symbol("SLSSpaceSetCompatID") ?? symbol("CGSSpaceSetCompatID"),
              let workspacePointer = symbol("SLSSetWindowListWorkspace") ?? symbol("CGSSetWindowListWorkspace") else {
            Log.write("Spostamento istantaneo tra scrivanie: funzioni di macOS non trovate")
            instantMovesWork = false
            return false
        }
        let setCompat = unsafeBitCast(compatPointer, to: SpaceSetCompatIDFn.self)
        let setWorkspace = unsafeBitCast(workspacePointer, to: SetWindowListWorkspaceFn.self)
        let tag: Int32 = 0x4F52_4D47
        let ids: [UInt32] = [windowID]
        _ = setCompat(connection, UInt64(spaceID), tag)
        _ = ids.withUnsafeBufferPointer { buffer in setWorkspace(connection, buffer.baseAddress!, 1, tag) }
        _ = setCompat(connection, UInt64(spaceID), 0)
        var arrived = false
        for _ in 0..<10 {
            if spaceIDs(forWindow: windowID).contains(spaceID) {
                arrived = true
                break
            }
            await Input.pause(0.1)
        }
        if instantMovesWork == nil {
            instantMovesWork = arrived
            Log.write("Spostamento istantaneo tra scrivanie: " + (arrived ? "funziona su questo Mac" : "non funziona su questo Mac, resta il trascinamento"))
        }
        return arrived
    }

    /// Porta il monitor sulla scrivania indicata (da 0) con ctrl + freccia.
    /// Porta un monitor sulla scrivania indicata (da 0), un passo alla volta con ctrl + freccia.
    /// Dopo ogni passo aspetta che macOS confermi il cambio: leggere la posizione durante l'animazione
    /// darebbe un numero vecchio e farebbe sbagliare il conto dei passi.
    @discardableResult
    static func switchDesktop(on display: LiveDisplay, to targetIndex: Int, displays: [LiveDisplay]) async -> Bool {
        guard layouts(for: displays)[display.id]?.spaceIDs.indices.contains(targetIndex) == true else { return false }
        let center = CGPoint(x: display.bounds.midX, y: display.bounds.midY)
        Input.moveMouse(to: center)
        await Input.pause(0.15)
        var silent = 0
        for _ in 0..<12 {
            guard let current = layouts(for: displays)[display.id]?.currentIndex else { return false }
            if current == targetIndex { return true }
            Input.pressDesktopArrow(right: targetIndex > current)
            var changed = false
            for _ in 0..<20 {
                await Input.pause(0.1)
                if layouts(for: displays)[display.id]?.currentIndex != current {
                    changed = true
                    break
                }
            }
            if changed {
                // Lascio finire l'animazione prima del passo successivo.
                await Input.pause(0.2)
            } else {
                silent += 1
                Log.write("Cambio scrivania su \(display.name): macOS non ha risposto (\(silent))")
                if silent >= 3 { break }
                Input.moveMouse(to: center)
                await Input.pause(0.3)
            }
        }
        let reached = layouts(for: displays)[display.id]?.currentIndex == targetIndex
        if !reached {
            let now = layouts(for: displays)[display.id]?.currentIndex.map { "\($0 + 1)" } ?? "?"
            Log.write("Cambio scrivania su \(display.name): volevo la \(targetIndex + 1), sono sulla \(now)")
        }
        return reached
    }

    /// Aspetta (al massimo 2 secondi) che la finestra risulti sulla scrivania indicata.
    static func waitForWindow(_ windowID: CGWindowID, onSpace spaceID: Int) async -> Bool {
        for _ in 0..<20 {
            if spaceIDs(forWindow: windowID).contains(spaceID) { return true }
            await Input.pause(0.1)
        }
        return false
    }

    /// Sposta una finestra dalla scrivania visibile a un'altra dello stesso monitor, quando c'è un monitor solo:
    /// la tiene per la barra in alto e cambia scrivania con ctrl + freccia. Prova fino a tre punti di presa
    /// e controlla alla fine su quale scrivania è finita.
    static func moveWindow(_ window: LiveWindow, on display: LiveDisplay, to targetIndex: Int, displays: [LiveDisplay]) async -> Bool {
        guard let layout = layouts(for: displays)[display.id], let current = layout.currentIndex,
              layout.spaceIDs.indices.contains(targetIndex) else { return false }
        if current == targetIndex { return true }
        guard let windowID = window.windowID else { return false }
        let targetSpace = layout.spaceIDs[targetIndex]
        if dragFailed {
            Log.write("\"\(window.title)\": il trascinamento non ha funzionato con un'altra finestra, non lo riprovo")
            return false
        }

        WindowManager.raise(window)
        await Input.pause(0.4)
        let start = WindowManager.frame(of: window.element) ?? window.frame
        Log.write("Trascino \"\(window.title)\" dalla scrivania \(current + 1) alla \(targetIndex + 1) di \(display.name)")

        var points: [CGPoint] = []
        for point in WindowManager.grabCandidates(of: window, frame: start) {
            if start.contains(point), WindowManager.isDraggableArea(point, pid: window.pid) {
                points.append(point)
            } else {
                Log.write("   punto \(Int(point.x)),\(Int(point.y)) scartato (\(WindowManager.roleAt(point)))")
            }
        }
        for (attempt, point) in points.prefix(2).enumerated() {
            if attempt > 0 {
                _ = await switchDesktop(on: display, to: current, displays: displays)
                WindowManager.raise(window)
                await Input.pause(0.4)
            }
            let role = WindowManager.roleAt(point)
            Input.moveMouse(to: point)
            await Input.pause(0.15)
            Input.mouse(.leftMouseDown, at: point)
            await Input.pause(0.2)
            Input.mouse(.leftMouseDragged, at: CGPoint(x: point.x + 3, y: point.y))
            await Input.pause(0.08)
            let held = CGPoint(x: point.x + 6, y: point.y)
            Input.mouse(.leftMouseDragged, at: held)
            await Input.pause(0.3)
            let steps = targetIndex - current
            for _ in 0..<abs(steps) {
                Input.pressDesktopArrow(right: steps > 0)
                await Input.pause(0.9)
                Input.mouse(.leftMouseDragged, at: held)
            }
            await Input.pause(0.3)
            Input.mouse(.leftMouseUp, at: held)
            await Input.pause(0.6)
            let spaces = spaceIDs(forWindow: windowID)
            let moved = spaces.contains(targetSpace)
            Log.write("   tentativo \(attempt + 1) dal punto \(Int(point.x)),\(Int(point.y)) (\(role)): " + (moved ? "spostata" : "NON spostata, spazi \(spaces)"))
            if moved { return true }
        }
        dragFailed = true
        return false
    }

    // MARK: Aggiungere e togliere scrivanie (Mission Control)

    /// Porta ogni monitor al numero di scrivanie della scena. Aggiunge in fondo e toglie solo le scrivanie
    /// oltre quel numero, così quelle della scena restano nel loro ordine. Non tocca un monitor con app
    /// a tutto schermo. Controlla il risultato e riprova una volta. Con allowRemove falso aggiunge soltanto.
    /// Con removeOccupied falso toglie solo le scrivanie in più vuote; vero, anche quelle con finestre
    /// (macOS sposta le finestre su un'altra scrivania).
    static func adjustSpaces(wanted: [CGDirectDisplayID: Int], displays: [LiveDisplay], allowRemove: Bool,
                             removeOccupied: Bool = false,
                             ignoring ghosts: Set<CGWindowID> = []) async -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for attempt in 1...2 {
            guard DisplayManager.fingerprint(DisplayManager.activeDisplays()) == DisplayManager.fingerprint(displays) else {
                Log.write("Monitor cambiati: non tocco le scrivanie")
                break
            }
            let current = layouts(for: displays)
            var toAdd: [CGDirectDisplayID: Int] = [:]
            var toRemove: [CGDirectDisplayID: Int] = [:]
            for (id, count) in wanted where count > 0 {
                guard let have = current[id]?.count else { continue }
                if count > have { toAdd[id] = count - have }
                if allowRemove, count < have { toRemove[id] = have - count }
            }
            guard !toAdd.isEmpty || !toRemove.isEmpty else { break }
            Log.write("Scrivanie, tentativo \(attempt): da aggiungere \(describe(toAdd, displays)), da togliere \(describe(toRemove, displays))")
            let result = await missionControlPass(toAdd: toAdd, toRemove: toRemove, current: current, displays: displays,
                                                  removeOccupied: removeOccupied, ignoring: ghosts)
            added += result.added
            removed += result.removed
            await Input.pause(0.4)
            // Se è cambiato un monitor che non dovevo toccare mi fermo: meglio una scrivania in meno che una a caso.
            let after = layouts(for: displays)
            let untouched = displays.filter { toAdd[$0.id] == nil && toRemove[$0.id] == nil }
            let wrong = untouched.filter { current[$0.id]?.count != after[$0.id]?.count }
            if !wrong.isEmpty {
                Log.write("Scrivanie cambiate su un monitor che non dovevo toccare (\(wrong.map(\.name).joined(separator: ", "))): mi fermo")
                break
            }
            // Se un tentativo non ha cambiato niente, un secondo non servirebbe.
            if result.added == 0 && result.removed == 0 { break }
        }
        let after = layouts(for: displays)
        for display in displays {
            guard let count = wanted[display.id], count > 0, let have = after[display.id]?.count else { continue }
            if have != count { Log.write("Scrivanie su \(display.name): \(have) invece di \(count)") }
        }
        Log.write("Scrivanie aggiunte: \(added), tolte: \(removed)")
        return (added, removed)
    }

    private static func describe(_ counts: [CGDirectDisplayID: Int], _ displays: [LiveDisplay]) -> String {
        guard !counts.isEmpty else { return "nessuna" }
        return counts.map { id, count in
            "\(count) su \(displays.first(where: { $0.id == id })?.name ?? "monitor \(id)")"
        }.joined(separator: ", ")
    }

    /// Apre Mission Control, aggiunge e toglie scrivanie, lo richiude.
    private static func missionControlPass(toAdd: [CGDirectDisplayID: Int], toRemove: [CGDirectDisplayID: Int],
                                           current: [CGDirectDisplayID: DesktopLayout],
                                           displays: [LiveDisplay], removeOccupied: Bool,
                                           ignoring ghosts: Set<CGWindowID>) async -> (added: Int, removed: Int) {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            Log.write("Dock non trovato: scrivanie non modificate")
            return (0, 0)
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        toggleMissionControl()

        // Aspetto che Mission Control sia aperto (fino a 3 secondi).
        var groups: [CGDirectDisplayID: AXUIElement] = [:]
        for _ in 0..<12 {
            await Input.pause(0.25)
            groups = displayGroups(in: dockElement)
            if !groups.isEmpty { break }
        }
        await Input.pause(0.5)
        groups = displayGroups(in: dockElement)
        Log.write("Mission Control: \(groups.count) monitor riconosciuti (\(groups.keys.map { "\($0)" }.joined(separator: ", ")))")
        // Un monitor che non mi aspettavo vuol dire che i monitor sono cambiati: non tocco niente.
        if groups.keys.contains(where: { id in !displays.contains(where: { $0.id == id }) }) {
            Log.write("Mission Control mostra un monitor che non mi aspettavo: non tocco le scrivanie")
            toggleMissionControl()
            await Input.pause(0.6)
            return (0, 0)
        }

        var added = 0
        var removed = 0
        for display in displays where toAdd[display.id] != nil || toRemove[display.id] != nil {
            // Il mouse in alto apre la barra delle scrivanie di quel monitor.
            Input.moveMouse(to: CGPoint(x: display.bounds.midX, y: display.bounds.minY + 4))
            await Input.pause(0.5)
            let group = displayGroups(in: dockElement)[display.id] ?? groups[display.id]

            if let count = toAdd[display.id] {
                if let button = addButton(for: display, group: group, dock: dockElement, displays: displays) {
                    for _ in 0..<count {
                        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                        if result == .success {
                            added += 1
                        } else {
                            Log.write("Pulsante + su \(display.name): errore \(result.rawValue)")
                        }
                        await Input.pause(0.35)
                    }
                } else {
                    Log.write("Pulsante per aggiungere scrivanie non trovato su \(display.name)")
                }
            }

            if let count = toRemove[display.id] {
                let userCount = current[display.id]?.count ?? 0
                guard totalSpaceCount(for: display, displays: displays) == userCount else {
                    Log.write("Su \(display.name) ci sono app a tutto schermo: non tolgo scrivanie")
                    continue
                }
                var lists: [AXUIElement] = []
                if let group { collect(identifier: "mc.spaces.list", in: group, depth: 0, into: &lists) }
                if lists.isEmpty {
                    var all: [AXUIElement] = []
                    collect(identifier: "mc.spaces.list", in: dockElement, depth: 0, into: &all)
                    lists = all.filter { isOn(display, $0) }
                }
                for list in lists {
                    let buttons = WindowManager.children(of: list)
                        .compactMap { element -> (AXUIElement, CGFloat)? in
                            guard let point = WindowManager.position(of: element) else { return nil }
                            return (element, point.x)
                        }
                        .sorted { $0.1 < $1.1 }
                        .map { $0.0 }
                    guard buttons.count == userCount, buttons.count > count else {
                        Log.write("Scrivanie di \(display.name) in Mission Control: \(buttons.count), attese \(userCount)")
                        continue
                    }
                    // Solo le scrivanie oltre quelle della scena, dalla fine.
                    let keep = userCount - count
                    let spaceIDs = current[display.id]?.spaceIDs ?? []
                    let occupied = occupiedSpaces(ignoring: ghosts)
                    var removable: [AXUIElement] = []
                    for (position, button) in buttons.enumerated().reversed() where position >= keep {
                        let busy = spaceIDs[safe: position].map { occupied.contains($0) } ?? true
                        if busy && !removeOccupied {
                            Log.write("Scrivania \(position + 1) di \(display.name): in più ma con finestre, la toglie il richiamo completo")
                            continue
                        }
                        Log.write("Scrivania \(position + 1) di \(display.name): in più" + (busy ? ", con finestre" : ", vuota") + ", la tolgo")
                        removable.append(button)
                    }
                    for button in removable {
                        guard let action = removeAction(of: button) else {
                            Log.write("Azione per togliere la scrivania non trovata")
                            break
                        }
                        if AXUIElementPerformAction(button, action as CFString) == .success { removed += 1 }
                        await Input.pause(0.35)
                    }
                    break
                }
            }
        }

        await Input.pause(0.3)
        toggleMissionControl()
        await Input.pause(0.6)
        return (added, removed)
    }

    /// Scrivanie su cui c'è almeno una finestra normale di un'app.
    static func occupiedSpaces(ignoring ghosts: Set<CGWindowID> = []) -> Set<Int> {
        let regular = Set(WindowManager.regularApps().map(\.processIdentifier))
        var result = Set<Int>()
        for window in WindowManager.systemWindows()
        where regular.contains(window.pid) && !ghosts.contains(window.id)
            && window.alpha > 0 && window.bounds.width >= 120 && window.bounds.height >= 90 {
            result.formUnion(spaceIDs(forWindow: window.id))
        }
        return result
    }

    /// Gruppi di Mission Control per monitor: macOS li marca con l'identificativo del monitor.
    private static func displayGroups(in dock: AXUIElement) -> [CGDirectDisplayID: AXUIElement] {
        var found: [AXUIElement] = []
        collect(identifier: "mc.display", in: dock, depth: 0, into: &found)
        var result: [CGDirectDisplayID: AXUIElement] = [:]
        for group in found {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(group, "AXDisplayID" as CFString, &value) == .success,
                  let number = value as? NSNumber else { continue }
            result[CGDirectDisplayID(number.uint32Value)] = group
        }
        return result
    }

    /// Pulsante "+" di Mission Control per quel monitor: prima dal gruppo del monitor, poi per posizione.
    private static func addButton(for display: LiveDisplay, group: AXUIElement?, dock: AXUIElement,
                                  displays: [LiveDisplay]) -> AXUIElement? {
        if let group {
            var buttons: [AXUIElement] = []
            collect(identifier: "mc.spaces.add", in: group, depth: 0, into: &buttons)
            if let button = buttons.first { return button }
        }
        var all: [AXUIElement] = []
        collect(identifier: "mc.spaces.add", in: dock, depth: 0, into: &all)
        Log.write("Pulsanti + in Mission Control: \(all.count) " + all.map { button in
            WindowManager.position(of: button).map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "(?)"
        }.joined(separator: " "))
        if let button = all.first(where: { isOn(display, $0) }) { return button }
        if all.count == 1, displays.count == 1 { return all[0] }
        // Niente tentativi a occhio: premere il + di un altro monitor aggiungerebbe una scrivania nel posto sbagliato.
        return nil
    }

    private static func distance(_ point: CGPoint?, _ target: CGPoint) -> CGFloat {
        guard let point else { return .greatestFiniteMagnitude }
        return abs(point.x - target.x) + abs(point.y - target.y)
    }

    private static func isOn(_ display: LiveDisplay, _ element: AXUIElement) -> Bool {
        guard let point = WindowManager.position(of: element) else { return false }
        return display.bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    private static func removeAction(of element: AXUIElement) -> String? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return nil }
        return list.first { $0.localizedCaseInsensitiveContains("remove") }
    }

    private static func toggleMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private static func collect(identifier: String, in element: AXUIElement, depth: Int, into result: inout [AXUIElement]) {
        guard depth < 10 else { return }
        if WindowManager.stringAttribute(element, "AXIdentifier") == identifier {
            result.append(element)
            return
        }
        for child in WindowManager.children(of: element) {
            collect(identifier: identifier, in: child, depth: depth + 1, into: &result)
        }
    }
}
