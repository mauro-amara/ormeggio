import AppKit

/// Una finestra del browser letta con AppleScript: titolo, posizione e schede.
struct BrowserWindowInfo {
    let index: Int
    let title: String
    let frame: CGRect
    let urls: [String]
}

struct ChromeProfile {
    let directory: String
    let name: String
}

/// Chrome e Safari: schede aperte, profili di Chrome, apertura di nuove finestre.
/// La prima volta macOS chiede il permesso di controllare il browser.
@MainActor
enum BrowserBridge {
    static let chromeID = "com.google.Chrome"
    static let safariID = "com.apple.Safari"

    static func isBrowser(_ bundleID: String) -> Bool {
        bundleID == chromeID || bundleID == safariID
    }

    // MARK: Lettura delle schede

    /// Finestre e schede del browser. Va chiamata solo se il browser è aperto,
    /// altrimenti AppleScript lo avvierebbe.
    static func windows(bundleID: String) -> [BrowserWindowInfo] {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return [] }
        let appName = bundleID == chromeID ? "Google Chrome" : "Safari"
        let source = """
        tell application "\(appName)"
            set output to ""
            set sep to (character id 30)
            repeat with w in every window
                try
                    set b to bounds of w
                    set addresses to ""
                    repeat with t in every tab of w
                        set addresses to addresses & (URL of t) & sep
                    end repeat
                    set output to output & (index of w) & tab & (name of w) & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & tab & addresses & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let text = run(source) else { return [] }
        return text.split(separator: "\n").compactMap { line -> BrowserWindowInfo? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 7, let index = Int(parts[0]),
                  let left = Double(parts[2]), let top = Double(parts[3]),
                  let right = Double(parts[4]), let bottom = Double(parts[5]) else { return nil }
            let urls = parts[6].split(separator: "\u{1E}").map(String.init).filter { !$0.isEmpty && $0 != "missing value" }
            return BrowserWindowInfo(
                index: index,
                title: parts[1],
                frame: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                urls: urls
            )
        }
    }

    /// Abbina una finestra (titolo e posizione) a quella letta con AppleScript.
    static func match(title: String, frame: CGRect, in infos: [BrowserWindowInfo]) -> Int? {
        guard !infos.isEmpty else { return nil }
        func gap(_ info: BrowserWindowInfo) -> CGFloat {
            abs(info.frame.minX - frame.minX) + abs(info.frame.minY - frame.minY)
                + abs(info.frame.width - frame.width) + abs(info.frame.height - frame.height)
        }
        let sameTitle = infos.indices.filter { !title.isEmpty && infos[$0].title == title }
        if let best = sameTitle.min(by: { gap(infos[$0]) < gap(infos[$1]) }) { return best }
        guard let best = infos.indices.min(by: { gap(infos[$0]) < gap(infos[$1]) }) else { return nil }
        return gap(infos[best]) < 80 ? best : nil
    }

    // MARK: Profili di Chrome

    static func chromeProfiles() -> [ChromeProfile] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { key, value -> ChromeProfile? in
            guard let info = value as? [String: Any] else { return nil }
            return ChromeProfile(directory: key, name: info["name"] as? String ?? key)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Riconosce il profilo di una finestra di Chrome dal pulsante del profilo nella barra degli strumenti.
    static func detectProfile(of window: LiveWindow, profiles: [ChromeProfile]) -> String? {
        guard profiles.count > 1 else { return profiles.first?.directory }
        // Chrome espone l'albero completo dell'Accessibilità solo se glielo si chiede.
        let app = AXUIElementCreateApplication(window.pid)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var queue: [AXUIElement] = [window.element]
        var visited = 0
        var best: ChromeProfile?
        while !queue.isEmpty, visited < 600 {
            let element = queue.removeFirst()
            visited += 1
            let role = WindowManager.stringAttribute(element, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXPopUpButtonRole || role == "AXMenuButton" {
                let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { WindowManager.stringAttribute(element, $0) }
                for profile in profiles where texts.contains(where: { $0.localizedCaseInsensitiveContains(profile.name) }) {
                    if best == nil || profile.name.count > best!.name.count { best = profile }
                }
            }
            if role == "AXWebArea" { continue }
            queue.append(contentsOf: WindowManager.children(of: element))
        }
        return best?.directory
    }

    // MARK: Zoom di Chrome

    /// Livelli di zoom dei siti salvati nelle preferenze del profilo Chrome.
    /// Il livello è quello di Chrome: 0 = 100%, ogni unità vale un fattore 1,2.
    static func chromeZoomLevels(profile: String) -> (defaultLevel: Double, hosts: [String: Double]) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
            .appendingPathComponent(profile)
            .appendingPathComponent("Preferences")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let partition = json["partition"] as? [String: Any] else { return (0, [:]) }
        var defaultLevel = 0.0
        if let defaults = partition["default_zoom_level"] as? [String: Any] {
            defaultLevel = defaults.values.compactMap { ($0 as? NSNumber)?.doubleValue }.first ?? 0
        } else if let value = partition["default_zoom_level"] as? NSNumber {
            defaultLevel = value.doubleValue
        }
        var hosts: [String: Double] = [:]
        if let partitions = partition["per_host_zoom_levels"] as? [String: Any] {
            for case let entries as [String: Any] in partitions.values {
                for (host, value) in entries {
                    if let number = value as? NSNumber {
                        hosts[host] = number.doubleValue
                    } else if let entry = value as? [String: Any], let number = entry["zoom_level"] as? NSNumber {
                        hosts[host] = number.doubleValue
                    }
                }
            }
        }
        return (defaultLevel, hosts)
    }

    static func host(of address: String) -> String? {
        guard let url = URL(string: address), let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// Scatti di zoom (cmd + e cmd -) tra il livello predefinito e quello voluto.
    static func chromeSteps(from defaultLevel: Double, to level: Double) -> Int {
        let presets: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
        func index(_ value: Double) -> Int {
            let factor = pow(1.2, value)
            return presets.indices.min(by: { abs(presets[$0] - factor) < abs(presets[$1] - factor) }) ?? 7
        }
        return index(level) - index(defaultLevel)
    }

    /// Mette in primo piano una scheda di Chrome aperta sul sito indicato, nella finestra più vicina alla posizione data.
    static func focusChromeTab(host: String, near frame: CGRect?) -> Bool {
        let infos = windows(bundleID: chromeID).filter { info in
            info.urls.contains { self.host(of: $0) == host }
        }
        guard !infos.isEmpty else { return false }
        let chosen: BrowserWindowInfo
        if let frame {
            chosen = infos.min(by: { distance($0.frame, frame) < distance($1.frame, frame) }) ?? infos[0]
        } else {
            chosen = infos[0]
        }
        guard let tabIndex = chosen.urls.firstIndex(where: { self.host(of: $0) == host }) else { return false }
        let source = """
        tell application "Google Chrome"
            set w to window \(chosen.index)
            set active tab index of w to \(tabIndex + 1)
            set index of w to 1
            activate
        end tell
        """
        _ = run(source)
        return true
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    // MARK: Apertura di finestre

    /// Apre una nuova finestra di Chrome nel profilo indicato, con le schede indicate.
    static func openChromeWindow(profile: String?, urls: [String]) {
        var arguments = ["-na", "Google Chrome", "--args"]
        if let profile { arguments.append("--profile-directory=\(profile)") }
        arguments.append("--new-window")
        arguments.append(contentsOf: urls)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            Log.write("Non riesco ad aprire Chrome: \(error.localizedDescription)")
        }
    }

    /// Apre una nuova finestra di Safari con le schede indicate.
    static func openSafariWindow(urls: [String]) {
        guard let first = urls.first else { return }
        var source = "tell application \"Safari\"\n"
        source += "make new document with properties {URL:\"\(escape(first))\"}\n"
        if urls.count > 1 {
            source += "tell front window\n"
            for url in urls.dropFirst() {
                source += "make new tab at end of tabs with properties {URL:\"\(escape(url))\"}\n"
            }
            source += "end tell\n"
        }
        source += "end tell"
        _ = run(source)
    }

    // MARK: AppleScript

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.write("AppleScript non riuscito: \(error)")
            return nil
        }
        return result.stringValue
    }
}
