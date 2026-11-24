import AppKit

/// "Invia segnalazione": un clic e la diagnostica parte.
/// Apre in Gmail la mail già scritta e la spedisce da sola con cmd Invio,
/// la scorciatoia di Gmail per inviare. Niente da compilare, niente da premere.
@MainActor
enum ReportSender {
    /// Casella che Claude legge: corregge e pubblica la versione nuova, che arriva a tutti da sola.
    static let address = "mauro.amara@sparkfabrik.com"

    enum Outcome {
        /// La mail è partita.
        case sent
        /// Gmail ha la mail pronta ma non sono sicuro che sia partita.
        case opened
        /// Gmail non si è aperto (per esempio non c'è un account collegato nel browser).
        case noGmail
    }

    private static let chromeID = "com.google.Chrome"
    private static let returnKey: CGKeyCode = 36

    static func send(report: String, version: String) async -> Outcome {
        let subject = "[Ormeggio] Segnalazione \(version) da \(NSFullUserName())"
        let body = "Segnalazione inviata da Ormeggio con un clic.\n\n" + report
        guard let url = composeURL(subject: subject, body: body) else { return .noGmail }

        // Chrome se c'è, perché è il browser con gli account di lavoro. Altrimenti il browser predefinito.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let browser: NSRunningApplication?
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeID) {
            browser = try? await NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration)
        } else {
            browser = try? await NSWorkspace.shared.open(url, configuration: configuration)
        }
        guard let pid = browser?.processIdentifier else {
            Log.write("Segnalazione: il browser non si è aperto")
            return .noGmail
        }

        // Aspetto che la pagina di Gmail sia in primo piano (al massimo 25 secondi).
        var gmailFront = false
        for _ in 0..<50 {
            await Input.pause(0.5)
            if isGmailFront(pid: pid) {
                gmailFront = true
                break
            }
        }
        guard gmailFront else {
            Log.write("Segnalazione: Gmail non è comparso. Titolo: \(focusedTitle(pid: pid) ?? "nessuno")")
            return .noGmail
        }
        // Gmail finisce di preparare la mail.
        await Input.pause(4)
        guard isGmailFront(pid: pid), let before = focusedTitle(pid: pid) else {
            Log.write("Segnalazione: la mail non è più in primo piano, non la invio io")
            return .opened
        }

        Input.key(returnKey, flags: .maskCommand)
        // Dopo l'invio Gmail cambia pagina: il titolo della finestra cambia.
        for _ in 0..<20 {
            await Input.pause(0.5)
            if let now = focusedTitle(pid: pid), now != before {
                Log.write("Segnalazione inviata (\(report.count) caratteri)")
                return .sent
            }
        }
        Log.write("Segnalazione: premuto cmd Invio, ma Gmail non ha cambiato pagina")
        return .opened
    }

    private static func composeURL(subject: String, body: String) -> URL? {
        // Codifico tutto tranne lettere e numeri inglesi: "&", "=" e "+" nel testo romperebbero l'indirizzo.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let query = "view=cm&fs=1&to=\(encode(address))&su=\(encode(subject))&body=\(encode(body))"
        return URL(string: "https://mail.google.com/mail/?" + query)
    }

    private static func isGmailFront(pid: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let title = focusedTitle(pid: pid) else { return false }
        return title.localizedCaseInsensitiveContains("gmail")
    }

    private static func focusedTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let ref = value, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return WindowManager.stringAttribute(ref as! AXUIElement, kAXTitleAttribute)
    }
}
