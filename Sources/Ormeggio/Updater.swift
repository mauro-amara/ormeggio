import AppKit

/// Descrizione dell'ultima versione pubblicata (file latest.json nel ramo builds).
struct UpdateInfo: Decodable {
    let version: String
    let build: Int
    let dmg: String
    let notes: String?
}

enum UpdateError: LocalizedError {
    case download
    case command(String)
    case notWritable

    var errorDescription: String? {
        switch self {
        case .download: return "non riesco a scaricare la nuova versione"
        case .command(let name): return "il comando \(name) non è riuscito"
        case .notWritable: return "non posso sostituire l'app in questa cartella"
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
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.check() }
        }
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

        let work = manager.temporaryDirectory.appendingPathComponent("ormeggio-update-\(UUID().uuidString)")
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        guard let remote = URL(string: Updater.feedBase + info.dmg) else { throw UpdateError.download }
        let (downloaded, response) = try await URLSession.shared.download(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let dmg = work.appendingPathComponent(info.dmg)
        try manager.moveItem(at: downloaded, to: dmg)

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

        // Lo script aspetta che Ormeggio si chiuda, sostituisce l'app e la riapre.
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target)"
        /usr/bin/ditto "\(staged.path)" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        /usr/bin/open "\(target)"
        rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("installa.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Lo script parte staccato da Ormeggio, così continua anche quando Ormeggio si chiude.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash \"\(scriptURL.path)\" >/dev/null 2>&1 &"]
        try process.run()
        process.waitUntilExit()

        UserDefaults.standard.set(currentVersion, forKey: "updatedFrom")
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
