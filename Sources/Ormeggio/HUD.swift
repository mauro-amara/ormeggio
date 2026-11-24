import AppKit
import SwiftUI

/// Cosa ha fatto Ormeggio: mostrato a schermo durante e dopo il richiamo o il salvataggio di una scena.
struct ActivityReport {
    enum Kind { case working, success, warning, failure }

    struct Line: Identifiable {
        /// Fatto (verde), da sapere (informazione, nessun problema), non riuscito (arancione).
        enum Tone { case done, info, warning }

        let id = UUID()
        var text: String
        var tone: Tone

        init(text: String, warning: Bool = false) {
            self.text = text
            self.tone = warning ? .warning : .done
        }

        init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }

        var warning: Bool { tone == .warning }
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var lines: [Line] = []
    /// Pulsante in fondo al riquadro, per la cosa da fare subito.
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

/// Il riquadro non è la finestra attiva: senza questo il primo clic su un pulsante andrebbe perso.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Piccola finestra in basso al centro dello schermo, sopra il Dock, che non ruba il fuoco.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Manda la diagnostica a Claude: è il pulsante che compare quando qualcosa non va.
    var sendDiagnostics: (@MainActor () -> Void)?

    func show(_ report: ActivityReport) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        var send: (@MainActor () -> Void)?
        if report.kind == .warning || report.kind == .failure, let sendDiagnostics {
            send = sendDiagnostics
        }
        let content = HUDView(report: report, onClose: { [weak self] in self?.hide() }, onSendDiagnostics: send)
        let hosting = FirstClickHostingView(rootView: content)
        let size = hosting.fittingSize

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect

        // Mentre Ormeggio sposta le finestre la finestrella non deve intercettare il mouse.
        panel.ignoresMouseEvents = report.kind == .working

        let screen = screenUnderMouse()
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 60)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        let seconds: Double?
        switch report.kind {
        case .working: seconds = nil
        case .success:
            if report.action != nil || !report.lines.allSatisfy({ $0.tone == .done }) {
                seconds = 20
            } else {
                // Il tempo di leggere: qualche secondo in più per ogni riga.
                seconds = min(30, 6 + 3 * Double(report.lines.count))
            }
        case .warning, .failure: seconds = 20
        }
        if let seconds {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private struct HUDView: View {
    let report: ActivityReport
    let onClose: () -> Void
    let onSendDiagnostics: (@MainActor () -> Void)?

    private var tint: Color {
        switch report.kind {
        case .working: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private var symbol: String {
        switch report.kind {
        case .working: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    if report.kind == .working {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = report.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if report.kind != .working {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Chiudi")
                }
            }

            let done = report.lines.filter { $0.tone == .done }
            let infos = report.lines.filter { $0.tone == .info }
            let warnings = report.lines.filter { $0.tone == .warning }
            if !done.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(done) { line in
                        HUDLine(text: line.text, symbol: "checkmark.circle.fill", color: .green)
                    }
                }
            }
            if !warnings.isEmpty {
                Divider()
                Text("NON SONO RIUSCITO A SISTEMARE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(warnings) { line in
                        HUDLine(text: line.text, symbol: "exclamationmark.triangle.fill", color: .orange)
                    }
                }
            }
            if !infos.isEmpty {
                Divider()
                Text("DA SAPERE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(infos) { line in
                        HUDLine(text: line.text, symbol: "info.circle.fill", color: .secondary)
                    }
                }
            }
            if let onSendDiagnostics {
                Button {
                    onSendDiagnostics()
                } label: {
                    Label("Invia la diagnostica a Claude", systemImage: "paperplane")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
            if let title = report.actionTitle, let action = report.action {
                Button {
                    onClose()
                    action()
                } label: {
                    Text(title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
    }
}

private struct HUDLine: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
