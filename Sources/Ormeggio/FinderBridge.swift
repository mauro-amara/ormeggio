import AppKit

/// Una finestra del Finder: cartella mostrata e posizione.
struct FinderWindowInfo {
    let path: String
    let frame: CGRect
}

/// Legge le cartelle aperte nel Finder con AppleScript.
/// La prima volta macOS chiede il permesso di controllare il Finder.
@MainActor
enum FinderBridge {
    static let bundleID = "com.apple.finder"

    static func openFolders() -> [FinderWindowInfo] {
        let source = """
        tell application "Finder"
            set output to ""
            repeat with w in (every Finder window)
                try
                    set p to POSIX path of (target of w as alias)
                    set b to bounds of w
                    set output to output & p & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.write("Cartelle del Finder non leggibili: \(error)")
            return []
        }
        guard let text = result.stringValue else { return [] }
        return text.split(separator: "\n").compactMap { line -> FinderWindowInfo? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5,
                  let left = Double(parts[1]), let top = Double(parts[2]),
                  let right = Double(parts[3]), let bottom = Double(parts[4]) else { return nil }
            return FinderWindowInfo(path: parts[0], frame: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
    }

    /// Cartella di una finestra del Finder ricavata dal suo titolo, senza AppleScript: la cerca
    /// tra le cartelle di casa e tra le cartelle recenti del Finder. Non entra nelle cartelle,
    /// così macOS non chiede altri permessi.
    static func folder(forTitle title: String) -> String? {
        guard !title.isEmpty else { return nil }
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        // Cartelle standard: il Finder le mostra con il nome tradotto ("Scrivania", "Documenti").
        var standard: [String] = [home.path, "/Applications"]
        for name in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public",
                     "Library/Mobile Documents/com~apple~CloudDocs"] {
            standard.append(home.appendingPathComponent(name).path)
        }
        for path in standard where manager.displayName(atPath: path) == title || (path as NSString).lastPathComponent == title {
            return path
        }
        // Cartelle recenti e cartelle di casa: confronto solo il nome, senza aprirle.
        var others = recentFolders()
        if let children = try? manager.contentsOfDirectory(atPath: home.path) {
            others += children.filter { !$0.hasPrefix(".") }.map { home.appendingPathComponent($0).path }
        }
        return others.first { ($0 as NSString).lastPathComponent == title }
    }

    /// Cartelle aperte di recente nel Finder (menu Vai > Cartelle recenti). Il percorso lo leggo
    /// dal segnalibro salvato dal Finder, senza toccare la cartella.
    static func recentFolders() -> [String] {
        guard let entries = CFPreferencesCopyAppValue("FXRecentFolders" as CFString, "com.apple.finder" as CFString) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> String? in
            guard let data = entry["file-bookmark"] as? Data else { return nil }
            return URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
        }
    }

    /// Titolo che il Finder mostra per una cartella (per esempio "Scrivania").
    static func displayName(of path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    /// Apre la cartella in una finestra del Finder.
    /// Cartella su un disco esterno che adesso non c'è o che è solo in lettura, come il DMG di un'installazione.
    /// Sono finestre di passaggio: non le salvo in una scena e non provo a riaprirle.
    static func isTemporaryVolume(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        let root = URL(fileURLWithPath: "/Volumes/" + parts[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return true }
        let values = try? root.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true
    }

    static func open(folder path: String) {
        // Non controllo la cartella prima: per quelle in Scrivania o Documenti macOS chiederebbe un permesso.
        // La apre il Finder, che può.
        // Mostro la cartella nel Finder: così non apro mai un'app o un documento che si trovasse a quel percorso.
        // In un altro thread: se il Finder è lento a rispondere (per esempio su una cartella nel cloud
        // subito dopo un cambio di monitor) il richiamo non resta fermo ad aspettarlo.
        DispatchQueue.global(qos: .userInitiated).async {
            if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) {
                Task { @MainActor in Log.write("Cartella non aperta: \(path)") }
            }
        }
    }
}
