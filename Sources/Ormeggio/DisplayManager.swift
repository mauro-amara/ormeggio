import AppKit
import CoreGraphics

/// Un monitor collegato in questo momento.
struct LiveDisplay {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let isBuiltin: Bool
    let bounds: CGRect
    let mode: DisplayMode?
}

@MainActor
enum DisplayManager {
    /// Monitor attivi (esclusi quelli in duplicazione dello schermo).
    static func activeDisplays() -> [LiveDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id -> LiveDisplay? in
            if CGDisplayMirrorsDisplay(id) != 0 { return nil }
            let builtin = CGDisplayIsBuiltin(id) != 0
            return LiveDisplay(
                id: id,
                key: key(for: id, builtin: builtin),
                name: name(for: id, builtin: builtin),
                isBuiltin: builtin,
                bounds: CGDisplayBounds(id),
                mode: currentMode(of: id)
            )
        }
    }

    /// Identifica la combinazione di monitor collegati, indipendentemente dall'ordine.
    static func fingerprint(_ displays: [LiveDisplay]) -> String {
        displays.map(\.key).sorted().joined(separator: "+")
    }

    private static func key(for id: CGDirectDisplayID, builtin: Bool) -> String {
        if builtin { return "builtin" }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    private static func name(for id: CGDirectDisplayID, builtin: Bool) -> String {
        if let screen = screen(for: id) { return screen.localizedName }
        return builtin ? "Display integrato" : "Monitor esterno"
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }
    }

    static func currentMode(of id: CGDirectDisplayID) -> DisplayMode? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayMode(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate
        )
    }

    /// Imposta la risoluzione (e quindi la scala) del monitor. Restituisce true se è cambiata.
    static func setMode(_ target: DisplayMode, on id: CGDirectDisplayID) -> Bool {
        if let current = currentMode(of: id), current.sameResolution(as: target) { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return false }
        let matching = modes.filter {
            $0.width == target.width && $0.height == target.height
                && $0.pixelWidth == target.pixelWidth && $0.pixelHeight == target.pixelHeight
                && $0.isUsableForDesktopGUI()
        }
        guard let best = matching.min(by: {
            abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate)
        }) else {
            Log.write("Risoluzione \(target.label) non disponibile sul monitor \(id)")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        _ = CGConfigureDisplayWithDisplayMode(config, id, best, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success {
            Log.write("Cambio di risoluzione non riuscito sul monitor \(id): \(result.rawValue)")
        }
        return result == .success
    }
}
