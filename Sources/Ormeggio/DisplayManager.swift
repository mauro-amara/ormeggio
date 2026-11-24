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
    /// Prova prima con le API pubbliche; se la scala non è nell'elenco pubblico usa quello completo di macOS.
    static func setMode(_ target: DisplayMode, on id: CGDirectDisplayID) -> Bool {
        if let current = currentMode(of: id), current.sameResolution(as: target) { return false }
        if setPublicMode(target, on: id) { return true }
        if setPrivateMode(target, on: id) { return true }
        Log.write("Scala \(target.label) (\(target.pixelWidth)×\(target.pixelHeight) pixel) non disponibile sul monitor \(id)")
        return false
    }

    private static func setPublicMode(_ target: DisplayMode, on id: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return false }
        let matching = modes.filter {
            $0.width == target.width && $0.height == target.height
                && $0.pixelWidth == target.pixelWidth && $0.pixelHeight == target.pixelHeight
        }
        guard let best = matching.min(by: {
            abs($0.refreshRate - target.refreshRate) < abs($1.refreshRate - target.refreshRate)
        }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        _ = CGConfigureDisplayWithDisplayMode(config, id, best, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success { Log.write("Cambio di scala pubblico non riuscito: \(result.rawValue)") }
        return result == .success && (currentMode(of: id)?.sameResolution(as: target) ?? true)
    }

    /// Scale disponibili, per la diagnostica.
    static func availableScales(of id: CGDirectDisplayID) -> [String] {
        let modes = privateModes(of: id)
        guard !modes.isEmpty else { return ["non leggibili"] }
        var seen = Set<String>()
        return modes.filter { $0.density > 1 }.compactMap { mode -> String? in
            let label = "\(mode.width)×\(mode.height)"
            return seen.insert(label).inserted ? label : nil
        }
    }

    // MARK: Elenco completo delle modalità (funzioni private, come displayplacer)

    private struct PrivateMode {
        let number: Int32
        let width: Int
        let height: Int
        let density: Double
        let refresh: Int
    }

    private typealias NumberOfModesFn = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ModeDescriptionFn = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Int32
    private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, UInt32, Int32) -> Int32

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static func privateModes(of id: CGDirectDisplayID) -> [PrivateMode] {
        guard let countPointer = symbol("CGSGetNumberOfDisplayModes"),
              let describePointer = symbol("CGSGetDisplayModeDescriptionOfLength") else { return [] }
        var count: Int32 = 0
        guard unsafeBitCast(countPointer, to: NumberOfModesFn.self)(id, &count) == 0, count > 0 else { return [] }
        let describe = unsafeBitCast(describePointer, to: ModeDescriptionFn.self)
        let length = 0xD4
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 0x100, alignment: 8)
        defer { buffer.deallocate() }
        var result: [PrivateMode] = []
        for index in 0..<count {
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 0x100)
            guard describe(id, index, buffer, Int32(length)) == 0 else { continue }
            let number = buffer.loadUnaligned(fromByteOffset: 0x0, as: UInt32.self)
            let width = buffer.loadUnaligned(fromByteOffset: 0x8, as: UInt32.self)
            let height = buffer.loadUnaligned(fromByteOffset: 0xC, as: UInt32.self)
            let refresh = buffer.loadUnaligned(fromByteOffset: 0xBE, as: UInt16.self)
            let density = buffer.loadUnaligned(fromByteOffset: 0xD0, as: Float.self)
            result.append(PrivateMode(number: Int32(bitPattern: number), width: Int(width), height: Int(height),
                                      density: Double(density), refresh: Int(refresh)))
        }
        return result
    }

    private static func setPrivateMode(_ target: DisplayMode, on id: CGDirectDisplayID) -> Bool {
        guard let configurePointer = symbol("CGSConfigureDisplayMode") else { return false }
        let wantedDensity = Double(target.pixelWidth) / Double(max(target.width, 1))
        let candidates = privateModes(of: id).filter {
            $0.width == target.width && $0.height == target.height && abs($0.density - wantedDensity) < 0.1
        }
        guard let best = candidates.min(by: {
            abs(Double($0.refresh) - target.refreshRate) < abs(Double($1.refresh) - target.refreshRate)
        }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        _ = unsafeBitCast(configurePointer, to: ConfigureModeFn.self)(config, id, best.number)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success { Log.write("Cambio di scala (elenco completo) non riuscito: \(result.rawValue)") }
        return result == .success
    }
}
