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

    /// Titolo che il Finder mostra per una cartella (per esempio "Scrivania").
    static func displayName(of path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    /// Apre la cartella in una finestra del Finder.
    static func open(folder path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            Log.write("Cartella non trovata: \(path)")
            return
        }
        _ = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
