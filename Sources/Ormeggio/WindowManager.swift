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

    /// Finestre standard, non ridotte a icona, di un'app.
    static func windows(of app: NSRunningApplication) -> [LiveWindow] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(axApp, 1.0)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.compactMap { element -> LiveWindow? in
            guard stringAttribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole else { return nil }
            if boolAttribute(element, kAXMinimizedAttribute) == true { return nil }
            guard let rect = frame(of: element) else { return nil }
            return LiveWindow(
                element: element,
                pid: app.processIdentifier,
                bundleID: bundleID,
                appName: app.localizedName ?? bundleID,
                title: stringAttribute(element, kAXTitleAttribute) ?? "",
                frame: rect,
                windowID: windowID(of: element),
                documentURL: stringAttribute(element, kAXDocumentAttribute)
            )
        }
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
