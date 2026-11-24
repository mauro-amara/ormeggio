import AppKit
import ApplicationServices

/// Zoom dentro le app (quello di cmd + e cmd -).
///
/// Ormeggio usa le voci del menu dell'app che hanno come scorciatoia cmd 0, cmd + e cmd -:
/// così funziona con qualsiasi lingua e tastiera.
@MainActor
enum ZoomManager {
    struct Commands {
        var reset: AXUIElement?
        var zoomIn: AXUIElement?
        var zoomOut: AXUIElement?
    }

    /// Cerca nel menu dell'app le voci "Dimensioni effettive", "Zoom avanti" e "Zoom indietro".
    static func commands(pid: pid_t) -> Commands {
        var result = Commands()
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let barRef = value, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return result }
        var queue: [(AXUIElement, Int)] = [(barRef as! AXUIElement, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if WindowManager.stringAttribute(element, kAXRoleAttribute) == kAXMenuItemRole,
               let character = WindowManager.stringAttribute(element, kAXMenuItemCmdCharAttribute),
               intAttribute(element, kAXMenuItemCmdModifiersAttribute) == 0 {
                switch character {
                case "0": if result.reset == nil { result.reset = element }
                case "+", "=": if result.zoomIn == nil { result.zoomIn = element }
                case "-", "−": if result.zoomOut == nil { result.zoomOut = element }
                default: break
                }
            }
            if depth < 4 {
                queue.append(contentsOf: WindowManager.children(of: element).map { ($0, depth + 1) })
            }
        }
        return result
    }

    /// Porta lo zoom della finestra in primo piano dell'app a "normale" più gli scatti indicati.
    @discardableResult
    static func setZoom(pid: pid_t, steps: Int, appName: String) async -> Bool {
        _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        await Input.pause(0.3)
        let commands = commands(pid: pid)
        guard let reset = commands.reset else {
            Log.write("Zoom di \(appName): voce per tornare al 100% non trovata nel menu")
            return false
        }
        _ = AXUIElementPerformAction(reset, kAXPressAction as CFString)
        await Input.pause(0.25)
        guard steps != 0 else { return true }
        guard let step = steps > 0 ? commands.zoomIn : commands.zoomOut else {
            Log.write("Zoom di \(appName): voce per ingrandire o rimpicciolire non trovata nel menu")
            return false
        }
        for _ in 0..<abs(steps) {
            _ = AXUIElementPerformAction(step, kAXPressAction as CFString)
            await Input.pause(0.2)
        }
        return true
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
