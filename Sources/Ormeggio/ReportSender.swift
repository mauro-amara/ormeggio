import AppKit
import CryptoKit

/// "Invia segnalazione": un clic e la diagnostica parte, cifrata, verso la casella privata delle segnalazioni.
@MainActor
enum ReportSender {
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
}
