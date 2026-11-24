import AppKit
import CryptoKit

/// Descrizione dell'ultima versione pubblicata (file latest.json nel ramo builds).
struct UpdateInfo: Decodable {
    let version: String
    let build: Int
    let dmg: String
    let notes: String?
    /// Impronta SHA-256 del DMG, scritta dalla compilazione: il file scaricato deve essere identico.
    let sha256: String?
}

enum UpdateError: LocalizedError {
    case download
    case command(String)
    case notWritable
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .download: return "non riesco a scaricare la nuova versione"
        case .command(let name): return "il comando \(name) non è riuscito"
        case .notWritable: return "non posso sostituire l'app in questa cartella"
        case .invalid(let reason): return "la versione scaricata non supera i controlli (\(reason))"
        }
    }
}

/// Aggiornamenti: controlla se c'è una versione nuova, la scarica, sostituisce l'app e la riapre.
@MainActor
final class Updater {
    /// Dove la compilazione su GitHub pubblica DMG e latest.json.
    static let feedBase = "https://raw.githubusercontent.com/mauro-amara/ormeggio/builds/"

    private(set) var available: UpdateInfo?
    var onChange: (@MainActor () -> Void)?
    /// Chiamata quando c'è una versione nuova: l'app la installa da sola.
    var onAvailable: (@MainActor (UpdateInfo) -> Void)?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    func start() {
        Task { @MainActor in
            await Input.pause(10)
            await self.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.check() }
        }
    }

    /// L'ultima versione pubblicata, senza installare niente (per leggerne le novità).
    func latestPublished() async -> UpdateInfo? {
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: Updater.feedBase + "latest.json?t=\(stamp)") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    /// Controlla se c'è una versione più recente. Restituisce nil se non c'è o se il controllo fallisce.
    @discardableResult
    func check() async -> UpdateInfo? {
        let stamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: Updater.feedBase + "latest.json?t=\(stamp)") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            available = info.build > currentBuild ? info : nil
            onChange?()
            if let available {
                Log.write("Aggiornamento disponibile: \(available.version)")
                onAvailable?(available)
            }
            return available
        } catch {
            Log.write("Controllo aggiornamenti non riuscito: \(error.localizedDescription)")
            return nil
        }
    }

    /// Scarica la nuova versione, chiude Ormeggio, sostituisce l'app e la riapre.
    func install(_ info: UpdateInfo) async throws {
        let manager = FileManager.default
        let target = Bundle.main.bundlePath
        let folder = (target as NSString).deletingLastPathComponent
        guard !target.contains("AppTranslocation"), manager.isWritableFile(atPath: folder) else {
            throw UpdateError.notWritable
        }

        // Il nome del file arriva da internet: lo accetto solo nella forma prevista, senza cartelle.
        guard info.dmg.range(of: #"^Ormeggio-[0-9]+(\.[0-9]+)*\.dmg$"#, options: .regularExpression) != nil else {
            throw UpdateError.invalid("nome del file")
        }
        guard let expectedHash = info.sha256?.lowercased(), expectedHash.count == 64 else {
            throw UpdateError.invalid("manca l'impronta del file")
        }

        let work = manager.temporaryDirectory.appendingPathComponent("ormeggio-update-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        guard let remote = URL(string: Updater.feedBase + info.dmg) else { throw UpdateError.download }
        let (downloaded, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let dmg = work.appendingPathComponent(info.dmg)
        try manager.moveItem(at: downloaded, to: dmg)

        // Il DMG deve essere esattamente quello pubblicato dalla compilazione.
        let digest = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else {
            try? manager.removeItem(at: work)
            throw UpdateError.invalid("impronta diversa")
        }

        let mount = work.appendingPathComponent("volume")
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        try Updater.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
        let staged = work.appendingPathComponent("Ormeggio.app")
        do {
            try Updater.run("/usr/bin/ditto", [mount.appendingPathComponent("Ormeggio.app").path, staged.path])
        } catch {
            _ = try? Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        // L'app scaricata deve essere Ormeggio, della versione annunciata, con la firma intatta.
        let plist = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              plist?["CFBundleVersion"] as? String == String(info.build) else {
            throw UpdateError.invalid("app diversa da quella annunciata")
        }
        do {
            try Updater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            throw UpdateError.invalid("firma non valida")
        }

        // Lo script aspetta che Ormeggio si chiuda, mette la versione nuova accanto a quella vecchia,
        // le scambia e riapre Ormeggio. Se qualcosa va storto rimette la vecchia.
        // I percorsi gli arrivano come argomenti, mai dentro il testo dello script.
        let script = """
        #!/bin/bash
        pid="$1"; target="$2"; staged="$3"; work="$4"
        case "$target" in *.app) ;; *) exit 1 ;; esac
        while kill -0 "$pid" 2>/dev/null; do sleep 0.3; done
        if ! /usr/bin/ditto "$staged" "$target.nuova"; then rm -rf "$target.nuova"; /usr/bin/open "$target"; exit 1; fi
        if mv "$target" "$work/precedente.app"; then
          if ! mv "$target.nuova" "$target"; then mv "$work/precedente.app" "$target"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$target" 2>/dev/null
        /usr/bin/open "$target"
        rm -rf "$work" "$target.nuova"
        """
        let scriptURL = work.appendingPathComponent("installa.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Lo script parte staccato da Ormeggio, così continua anche quando Ormeggio si chiude.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
                             scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), target, staged.path, work.path]
        try process.run()
        process.waitUntilExit()

        UserDefaults.standard.set(currentVersion, forKey: "updatedFrom")
        // Le novità le mostro dopo il riavvio, nella versione nuova.
        UserDefaults.standard.set(info.notes ?? "", forKey: "pendingUpdateNotes")
        Log.write("Aggiornamento alla \(info.version): installazione avviata")
        NSApp.terminate(nil)
    }

    /// Indirizzo del DMG, per scaricarlo a mano se l'aggiornamento automatico non è possibile.
    func downloadURL(for info: UpdateInfo) -> URL? {
        URL(string: Updater.feedBase + info.dmg)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.command((executable as NSString).lastPathComponent)
        }
    }
}
