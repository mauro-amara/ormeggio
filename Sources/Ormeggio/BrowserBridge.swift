import AppKit
import CoreServices

/// Una finestra del browser letta con AppleScript: titolo, posizione e schede.
struct BrowserWindowInfo {
    let index: Int
    /// Identificativo della finestra per il browser: non cambia quando la finestra va in primo piano.
    let id: Int?
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
                    set wid to ""
                    try
                        set wid to (id of w) as text
                    end try
                    set output to output & (index of w) & tab & wid & tab & (name of w) & tab & (item 1 of b) & tab & (item 2 of b) & tab & (item 3 of b) & tab & (item 4 of b) & tab & addresses & linefeed
                end try
            end repeat
            return output
        end tell
        """
        guard let text = run(source) else { return [] }
        return text.split(separator: "\n").compactMap { line -> BrowserWindowInfo? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 8, let index = Int(parts[0]),
                  let left = Double(parts[3]), let top = Double(parts[4]),
                  let right = Double(parts[5]), let bottom = Double(parts[6]) else { return nil }
            let urls = parts[7].split(separator: "\u{1E}").map(String.init).filter { !$0.isEmpty && $0 != "missing value" }
            return BrowserWindowInfo(
                index: index,
                id: Int(parts[1]),
                title: parts[2],
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
        // macOS aggiunge al titolo di Chrome il nome del profilo ("Pagina - Mauro (lavoro)"):
        // AppleScript dà solo il titolo della pagina.
        let sameTitle = infos.indices.filter { index in
            let pageTitle = infos[index].title
            return !title.isEmpty && !pageTitle.isEmpty && (title == pageTitle || title.hasPrefix(pageTitle + " - "))
        }
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

    /// Riconosce il profilo dal titolo della finestra: macOS lo aggiunge in fondo, per esempio
    /// "Gmail - Mauro (sparkfabrik.com)" oppure "Gmail - Caleffi".
    static func profile(fromTitle title: String, profiles: [ChromeProfile]) -> String? {
        guard profiles.count > 1 else { return profiles.first?.directory }
        guard !title.isEmpty else { return nil }
        let matches = profiles.filter { profile in
            title.hasSuffix("(\(profile.name))") || title.hasSuffix(" - \(profile.name)") || title == profile.name
        }
        return matches.max { $0.name.count < $1.name.count }?.directory
    }

    /// Titolo leggibile: senza il nome del profilo in fondo e non troppo lungo.
    static func readableTitle(_ title: String, profiles: [ChromeProfile]) -> String {
        var text = title
        for profile in profiles.sorted(by: { $0.name.count > $1.name.count }) {
            for suffix in ["(\(profile.name))", " - \(profile.name)"] where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                if suffix.hasPrefix("("), let range = text.range(of: " - ", options: .backwards) {
                    text = String(text[..<range.lowerBound])
                }
                break
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 45 ? String(text.prefix(44)) + "…" : text
    }

    /// Indirizzi di riunioni (Meet, Zoom, Teams...): una riunione finita non va riaperta.
    static func isMeeting(_ address: String) -> Bool {
        guard let host = host(of: address)?.lowercased() else { return false }
        let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "meet.jit.si"]
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) } || host.hasSuffix("webex.com")
    }

    /// Permesso Automazione (controllare un'altra app con AppleScript): 0 se concesso,
    /// -1743 se negato, -1744 se macOS deve ancora chiederlo, -600 se l'app è chiusa.
    /// Con ask a true macOS mostra la domanda e la funzione aspetta la risposta: non chiamarla dal thread principale.
    nonisolated static func automationCode(bundleID: String, ask: Bool) -> OSStatus {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return -600 }
        var address = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
        }
        guard created == OSErr(noErr) else { return OSStatus(created) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    /// Stato del permesso Automazione in parole, per la diagnostica.
    static func automationStatus(bundleID: String) -> String {
        switch automationCode(bundleID: bundleID, ask: false) {
        case 0: return "concessa"
        case -1743: return "NEGATA"
        case -1744: return "da chiedere"
        case -600: return "app chiusa"
        case let other: return "stato \(other)"
        }
    }

    /// Toglie le risposte date a macOS sul permesso Automazione, così le chiede di nuovo.
    static func resetAutomation() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", bundleID]
        try? process.run()
        process.waitUntilExit()
        Log.write("Permesso Automazione azzerato (esito \(process.terminationStatus))")
    }

    /// Profilo di una finestra quando il titolo non basta. Non leggo più gli elementi interni di Chrome:
    /// chiederli rende Chrome lentissimo a rispondere e le sue finestre spariscono per l'Accessibilità.
    /// Il profilo lo danno il titolo e i file di sessione.
    static func detectProfile(of window: LiveWindow, profiles: [ChromeProfile]) -> String? {
        profiles.count == 1 ? profiles.first?.directory : nil
    }

    /// Profili di Chrome aperti adesso, dal file Local State di Chrome.
    nonisolated static func openChromeProfileDirectories() -> Set<String> {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let active = profile["last_active_profiles"] as? [String] else { return [] }
        return Set(active)
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

    enum ChromeFocus {
        /// Nessuna finestra di Chrome ha una scheda con quel sito.
        case noTab
        case failed
        /// Scheda in primo piano; previousTab è la scheda che era attiva prima (da 1).
        case focused(previousTab: Int?)
    }

    /// Finestre di Chrome con una scheda sul sito indicato, dalla più probabile: prima quella con le schede
    /// più simili a quelle salvate nella scena (così prendo il profilo giusto anche quando più finestre
    /// stanno nella stessa posizione su scrivanie diverse), poi la più vicina alla posizione data.
    static func chromeCandidates(host: String, tabs: [String], near frame: CGRect?) -> [BrowserWindowInfo] {
        let infos = windows(bundleID: chromeID).filter { info in
            info.urls.contains { self.host(of: $0) == host }
        }
        let wantedURLs = Set(tabs)
        let wantedHosts = Set(tabs.compactMap { self.host(of: $0) })
        func similarity(_ info: BrowserWindowInfo) -> Double {
            let urls = Set(info.urls)
            let hosts = Set(info.urls.compactMap { self.host(of: $0) })
            let urlUnion = urls.union(wantedURLs).count
            let hostUnion = hosts.union(wantedHosts).count
            let urlScore = urlUnion == 0 ? 0 : Double(urls.intersection(wantedURLs).count) / Double(urlUnion)
            let hostScore = hostUnion == 0 ? 0 : Double(hosts.intersection(wantedHosts).count) / Double(hostUnion)
            return urlScore + hostScore / 2
        }
        return infos.sorted { lhs, rhs in
            let left = similarity(lhs)
            let right = similarity(rhs)
            if abs(left - right) > 0.001 { return left > right }
            guard let frame else { return false }
            return distance(lhs.frame, frame) < distance(rhs.frame, frame)
        }
    }

    /// Mette in primo piano la finestra e la scheda del sito indicato.
    static func focusChromeTab(in info: BrowserWindowInfo, host: String) -> ChromeFocus {
        guard let tabIndex = info.urls.firstIndex(where: { self.host(of: $0) == host }) else { return .noTab }
        let target = info.id.map { "(first window whose id is \($0))" } ?? "window \(info.index)"
        let source = """
        tell application "Google Chrome"
            set w to \(target)
            set previousTab to active tab index of w
            set active tab index of w to \(tabIndex + 1)
            set index of w to 1
            activate
            return previousTab as text
        end tell
        """
        guard let result = run(source) else { return .failed }
        let previous = Int(result.trimmingCharacters(in: .whitespacesAndNewlines))
        return .focused(previousTab: previous == tabIndex + 1 ? nil : previous)
    }

    /// Finestra di Chrome in primo piano: numero e titolo.
    static func focusedChromeWindow(pid: pid_t) -> (id: CGWindowID?, title: String)? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let ref = value, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let window = ref as! AXUIElement
        return (WindowManager.windowID(of: window), WindowManager.stringAttribute(window, kAXTitleAttribute) ?? "")
    }

    /// Chiude una finestra premendo il suo pulsante rosso. Solo quella indicata, mai un'altra.
    static func closeWindow(id: CGWindowID, pid: pid_t) -> Bool {
        guard let live = WindowManager.resolve(windowID: id, pid: pid) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(live.element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let ref = value, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(ref as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Profilo della finestra di Chrome in primo piano, dal suo titolo.
    static func frontChromeProfile(pid: pid_t, profiles: [ChromeProfile]) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let ref = value, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let window = ref as! AXUIElement
        guard let title = WindowManager.stringAttribute(window, kAXTitleAttribute) else { return nil }
        return profile(fromTitle: title, profiles: profiles)
    }

    /// Rimette attiva la scheda che c'era prima nella finestra di Chrome in primo piano.
    static func restoreChromeTab(_ index: Int) {
        _ = run("tell application \"Google Chrome\" to set active tab index of front window to \(index)")
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    // MARK: Apertura di finestre

    /// Apre le schede indicate nella finestra di Chrome del profilo usata per ultima
    /// (quella appena messa in primo piano), senza aprire una finestra nuova.
    static func openChromeTabs(profile: String?, urls: [String]) {
        guard !urls.isEmpty else { return }
        var arguments = ["-na", "Google Chrome", "--args"]
        if let profile { arguments.append("--profile-directory=\(profile)") }
        arguments.append(contentsOf: urls)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            Log.write("Non riesco ad aprire le schede in Chrome: \(error.localizedDescription)")
        }
    }

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
