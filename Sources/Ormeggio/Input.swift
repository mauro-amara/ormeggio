import AppKit
import CoreGraphics

/// Simula mouse e tastiera. Richiede il permesso di Accessibilità.
@MainActor
enum Input {
    private static let leftArrow: CGKeyCode = 123
    private static let rightArrow: CGKeyCode = 124

    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Ctrl + freccia: la scorciatoia standard di macOS per passare alla scrivania accanto.
    /// Il flag fn serve perché macOS tratta le frecce come tasti funzione.
    static func pressDesktopArrow(right: Bool) {
        key(right ? rightArrow : leftArrow, flags: [.maskControl, .maskSecondaryFn])
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func moveMouse(to point: CGPoint) {
        mouse(.mouseMoved, at: point)
    }

    static func mouse(_ type: CGEventType, at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        // Un clic vero ha il numero di clic: senza, macOS può non trattarlo come presa della finestra.
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
