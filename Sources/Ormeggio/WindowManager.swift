import AppKit
import ApplicationServices

/// Una finestra aperta in questo momento, letta con le API di Accessibilità.
struct LiveWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let windowID: CGWindowID?
    let documentURL: String?
    let isMinimized: Bool
    let isFullScreen: Bool
}

/// Una finestra vista dal server delle finestre di macOS, su qualsiasi scrivania.
struct SystemWindow {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let name: String?
    let alpha: Double
}

@MainActor
enum WindowManager {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// App con interfaccia (quelle che compaiono nel Dock), esclusa Ormeggio.
    static func regularApps() -> [NSRunningApplication] {
        let ownID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.bundleIdentifier != nil && $0.bundleIdentifier != ownID
        }
    }

    private static func axWindows(of app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(axApp, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    /// Finestre standard di un'app, comprese quelle ridotte nel Dock.
    static func windows(of app: NSRunningApplication) -> [LiveWindow] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        return axWindows(of: app).compactMap { element -> LiveWindow? in
            guard stringAttribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            guard let rect = frame(of: element) else { return nil }
            return LiveWindow(
                element: element,
                pid: app.processIdentifier,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                title: stringAttribute(element, kAXTitleAttribute) ?? "",
                frame: rect,
                windowID: windowID(of: element),
                documentURL: stringAttribute(element, kAXDocumentAttribute),
                isMinimized: boolAttribute(element, kAXMinimizedAttribute) == true,
                isFullScreen: boolAttribute(element, "AXFullScreen") == true
            )
        }
    }

    /// Identificativi di tutte le finestre che l'app espone, anche pannelli e dialoghi.
    static func allWindowIDs(of app: NSRunningApplication) -> Set<CGWindowID> {
        Set(axWindows(of: app).compactMap { windowID(of: $0) })
    }

    /// Tutte le finestre normali di tutte le scrivanie, dalla più in primo piano. Non sposta niente.
    static func systemWindows() -> [SystemWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry -> SystemWindow? in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            return SystemWindow(
                id: id,
                pid: pid,
                bounds: bounds,
                name: entry[kCGWindowName as String] as? String,
                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            )
        }
    }

    /// Ritrova la finestra con l'Accessibilità a partire dal suo identificativo.
    static func resolve(windowID: CGWindowID, pid: pid_t) -> LiveWindow? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return windows(of: app).first { $0.windowID == windowID }
    }

    static func setMinimized(_ element: AXUIElement, _ minimized: Bool) {
        _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func setFullScreen(_ element: AXUIElement, _ fullScreen: Bool) {
        _ = AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, fullScreen ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: Identificativo della finestra

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
    private static let getWindowPointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")

    /// Numero della finestra per macOS (funzione privata ma stabile da anni).
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let pointer = getWindowPointer else { return nil }
        var id: CGWindowID = 0
        let result = unsafeBitCast(pointer, to: GetWindowFn.self)(element, &id)
        return result == 0 && id != 0 ? id : nil
    }

    // MARK: Finestre sulle altre scrivanie

    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let remoteTokenPointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken")

    /// Titolo e documento (per il Finder la cartella) delle finestre di un'app su tutte le scrivanie,
    /// per numero di finestra. L'Accessibilità elenca solo le finestre della scrivania visibile:
    /// con questa funzione privata (la usano anche app come AltTab) si raggiungono anche le altre,
    /// senza cambiare scrivania.
    static func windowsOnAllDesktops(pid: pid_t) -> [CGWindowID: (title: String, document: String?)] {
        guard let pointer = remoteTokenPointer else { return [:] }
        let create = unsafeBitCast(pointer, to: CreateWithRemoteTokenFn.self)
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var result: [CGWindowID: (title: String, document: String?)] = [:]
        let started = Date()
        for elementID in UInt64(0)..<UInt64(1000) {
            if Date().timeIntervalSince(started) > 1.5 { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            _ = AXUIElementSetMessagingTimeout(element, 0.1)
            guard stringAttribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole,
                  let id = windowID(of: element) else { continue }
            result[id] = (stringAttribute(element, kAXTitleAttribute) ?? "", stringAttribute(element, kAXDocumentAttribute))
        }
        return result
    }

    // MARK: Azioni sulle finestre

    /// Porta la finestra in primo piano.
    static func raise(_ window: LiveWindow) {
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        _ = NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
    }

    /// Punto della barra del titolo da cui si può trascinare la finestra senza toccare pulsanti o schede:
    /// subito sopra e a sinistra del pulsante verde.
    static func grabPoint(of window: LiveWindow) -> CGPoint {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window.element, kAXZoomButtonAttribute as CFString, &value) == .success,
           let buttonRef = value, CFGetTypeID(buttonRef) == AXUIElementGetTypeID(),
           let point = position(of: buttonRef as! AXUIElement) {
            return CGPoint(x: point.x - 1, y: point.y - 1)
        }
        return CGPoint(x: window.frame.midX, y: window.frame.minY + 6)
    }

    /// Seleziona una voce della barra laterale (per esempio una pagina di Impostazioni di Sistema).
    @discardableResult
    static func selectSidebarItem(titled title: String, in window: AXUIElement) -> Bool {
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let element = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == kAXStaticTextRole,
               stringAttribute(element, kAXValueAttribute) == title || stringAttribute(element, kAXTitleAttribute) == title {
                var current: AXUIElement? = element
                for _ in 0..<5 {
                    guard let candidate = current else { break }
                    if stringAttribute(candidate, kAXRoleAttribute) == kAXRowRole {
                        let result = AXUIElementSetAttributeValue(candidate, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                        return result == .success
                    }
                    current = parent(of: candidate)
                }
            }
            queue.append(contentsOf: children(of: element))
        }
        return false
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Dimensione, posizione e di nuovo dimensione: serve quando la finestra cambia monitor.
    static func setFrame(_ element: AXUIElement, to rect: CGRect) {
        var size = rect.size
        var point = rect.origin
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        if let pointValue = AXValueCreate(.cgPoint, &point) {
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    // MARK: Utilità di Accessibilità

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parentRef = value, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
        return (parentRef as! AXUIElement)
    }

    static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let positionValue = value, CFGetTypeID(positionValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
