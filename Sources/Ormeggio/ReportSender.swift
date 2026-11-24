import AppKit
import CryptoKit

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

    // MARK: Canale diretto

    /// Repository privato dove arrivano le segnalazioni, come issue cifrate.
    private static let channelRepo = "mauro-amara/ormeggio-segnalazioni"
    /// Chiave di scrittura del repository, mascherata. Vuota finché il canale non è attivo.
    private static let maskedToken: [UInt8] = []
    private static let mask: UInt8 = 0x5A
    /// Chiave pubblica (X25519): con questa la segnalazione si chiude, e solo Claude la può aprire.
    private static let publicKey = "BHsKY6SRCfampfCTHs7aL0trgh1KTI6DehA1Vs1n/xU="

    /// Il canale diretto è attivo: la segnalazione parte in un secondo, senza aprire niente.
    static var hasDirectChannel: Bool { !maskedToken.isEmpty }

    /// Manda la segnalazione cifrata direttamente, senza mail e senza browser.
    static func sendDirect(report: String, version: String) async -> Bool {
        guard hasDirectChannel, let url = URL(string: "https://api.github.com/repos/\(channelRepo)/issues") else { return false }
        let token = String(decoding: maskedToken.map { $0 ^ mask }, as: UTF8.self)
        let plain = "Da: \(NSFullUserName())\nVersione: \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n" + report
        guard let sealed = seal(Data(plain.utf8)) else {
            Log.write("Segnalazione: non riesco a cifrarla")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Ormeggio", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let issue: [String: String] = ["title": "Segnalazione \(version)", "body": "ormeggio-v1:" + sealed.base64EncodedString()]
        request.httpBody = try? JSONSerialization.data(withJSONObject: issue)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.write("Segnalazione diretta: risposta \(status)")
            return status == 201
        } catch {
            Log.write("Segnalazione diretta non partita: \(error.localizedDescription)")
            return false
        }
    }

    /// Comprime e cifra: chiave effimera X25519, HKDF-SHA256, ChaCha20-Poly1305.
    /// Formato: chiave pubblica effimera (32 byte) + nonce (12) + testo cifrato + tag (16).
    /// Il primo byte del testo in chiaro dice se è compresso (1, deflate) o no (0).
    private static func seal(_ plain: Data) -> Data? {
        guard let raw = Data(base64Encoded: publicKey),
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { return nil }
        var inner = Data()
        if let compressed = try? (plain as NSData).compressed(using: .zlib) as Data {
            inner.append(1)
            inner.append(compressed)
        } else {
            inner.append(0)
            inner.append(plain)
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: recipient) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: ephemeral.publicKey.rawRepresentation,
                                                 sharedInfo: Data("ormeggio-segnalazione".utf8),
                                                 outputByteCount: 32)
        guard let box = try? ChaChaPoly.seal(inner, using: key) else { return nil }
        return ephemeral.publicKey.rawRepresentation + box.combined
    }

    // MARK: Gmail (finché il canale diretto non è attivo)

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
