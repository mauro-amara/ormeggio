import Foundation

enum Paths {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Ormeggio", isDirectory: true)
        // Cartella leggibile solo dalla persona: dentro ci sono titoli di finestre e indirizzi delle schede.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }()

    static var scenes: URL { folder.appendingPathComponent("scene.json") }
    static var log: URL { folder.appendingPathComponent("ormeggio.log") }
}

enum Log {
    /// Oltre questa dimensione il registro tiene solo la seconda metà.
    private static let maxBytes = 1_000_000

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: Paths.log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Paths.log)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.log.path)
        }
    }

    private static func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: Paths.log.path))?[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: Paths.log) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: 10) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: Paths.log, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.log.path)
    }
}

/// Archivio delle scene, salvato in ~/Library/Application Support/Ormeggio/scene.json
@MainActor
final class SceneStore {
    private(set) var scenes: [SavedScene] = []

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: Paths.scenes) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            scenes = try decoder.decode([SavedScene].self, from: data)
        } catch {
            Log.write("Errore nella lettura delle scene: \(error)")
            let backup = Paths.folder.appendingPathComponent("scene-illeggibili.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Paths.scenes, to: backup)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(scenes)
            try data.write(to: Paths.scenes, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.scenes.path)
        } catch {
            Log.write("Errore nel salvataggio delle scene: \(error)")
        }
        NotificationCenter.default.post(name: SceneStore.didChange, object: nil)
    }

    static let didChange = Notification.Name("OrmeggioScenesDidChange")

    /// Modifica una scena (nome, richiamo automatico).
    func update(id: UUID, _ change: (inout SavedScene) -> Void) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        change(&scenes[index])
        if scenes[index].autoApply {
            for other in scenes.indices where other != index && scenes[other].fingerprint == scenes[index].fingerprint {
                scenes[other].autoApply = false
            }
        }
        persist()
    }

    func scene(id: UUID) -> SavedScene? {
        scenes.first { $0.id == id }
    }

    func scene(named name: String) -> SavedScene? {
        scenes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// La scena da richiamare in automatico con questi monitor, se c'è.
    func autoScene(for fingerprint: String) -> SavedScene? {
        scenes.first { $0.autoApply && $0.fingerprint == fingerprint }
    }

    /// Salva la scena. Se esiste già una scena con lo stesso nome la sostituisce.
    func save(_ scene: SavedScene) {
        var scene = scene
        if let index = scenes.firstIndex(where: { $0.name.caseInsensitiveCompare(scene.name) == .orderedSame }) {
            scene.id = scenes[index].id
            // Lo zoom delle app lo sceglie l'utente: aggiornando la scena lo conservo.
            if scene.appZoom == nil { scene.appZoom = scenes[index].appZoom }
            if scene.icon == nil { scene.icon = scenes[index].icon }
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        if scene.autoApply {
            // Una sola scena automatica per ogni combinazione di monitor.
            for index in scenes.indices where scenes[index].id != scene.id && scenes[index].fingerprint == scene.fingerprint {
                scenes[index].autoApply = false
            }
        }
        persist()
    }

    func delete(id: UUID) {
        scenes.removeAll { $0.id == id }
        persist()
    }
}
