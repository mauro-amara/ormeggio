import Foundation
import CoreGraphics

/// Una finestra di Chrome come la descrive il file di sessione del suo profilo.
struct ChromeSessionWindow {
    let profile: String
    let id: Int32
    let bounds: CGRect?
    /// Indirizzi delle schede, nell'ordine della finestra.
    let tabs: [String]
    let titles: [String]
    /// Scheda in primo piano (da 0).
    let selectedIndex: Int

    var activeTitle: String {
        titles.indices.contains(selectedIndex) ? titles[selectedIndex] : (titles.first ?? "")
    }
}

/// Finestre e schede di Chrome lette dai file di sessione che Chrome tiene per ogni profilo
/// (~/Library/Application Support/Google/Chrome/<profilo>/Sessions/Session_*).
/// Non serve nessun permesso di macOS: sono file dell'utente, e dicono di ogni finestra
/// il profilo, la posizione e le schede. Chrome li aggiorna pochi secondi dopo ogni cambiamento.
enum ChromeSession {
    static func windows(profiles: [ChromeProfile]) -> [ChromeSessionWindow] {
        profiles.flatMap { windows(profileDirectory: $0.directory) }
    }

    static func windows(profileDirectory: String) -> [ChromeSessionWindow] {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
            .appendingPathComponent(profileDirectory)
            .appendingPathComponent("Sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let sessions = files.filter { $0.lastPathComponent.hasPrefix("Session_") }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        guard let latest = sessions.max(by: { modified($0) < modified($1) }),
              let data = try? Data(contentsOf: latest) else { return [] }
        return parse([UInt8](data), profile: profileDirectory)
    }

    // MARK: Formato SNSS

    private struct Tab {
        var window: Int32 = -1
        var index: Int32 = 0
        var navigations: [Int32: (url: String, title: String)] = [:]
        var selected: Int32 = -1
    }

    private struct Window {
        var bounds: CGRect?
        var selectedTab: Int32 = 0
        var type: Int32 = 0
    }

    /// Il file è una firma "SNSS", una versione e poi una sequenza di comandi:
    /// due byte di lunghezza, un byte con il tipo di comando, i dati. Rigiocandoli si ottiene lo stato attuale.
    static func parse(_ bytes: [UInt8], profile: String) -> [ChromeSessionWindow] {
        guard bytes.count >= 8, bytes[0] == 0x53, bytes[1] == 0x4E, bytes[2] == 0x53, bytes[3] == 0x53 else { return [] }
        let version = int32(bytes, 4)
        guard version == 1 || version == 3 else {
            Log.write("Sessione di Chrome (\(profile)): versione \(version) non letta")
            return []
        }
        var tabs: [Int32: Tab] = [:]
        var windows: [Int32: Window] = [:]
        var offset = 8
        while offset + 2 <= bytes.count {
            let size = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
            guard size >= 1, offset + size <= bytes.count else { break }
            let command = bytes[offset]
            let payload = Array(bytes[(offset + 1)..<(offset + size)])
            offset += size

            switch command {
            case 0: // scheda in una finestra: id finestra, id scheda
                guard payload.count >= 8 else { continue }
                let window = int32(payload, 0)
                let tab = int32(payload, 4)
                tabs[tab, default: Tab()].window = window
                if windows[window] == nil { windows[window] = Window() }
            case 2: // posizione della scheda nella finestra
                guard payload.count >= 8 else { continue }
                tabs[int32(payload, 0), default: Tab()].index = int32(payload, 4)
            case 5: // cronologia della scheda tagliata dal fondo
                guard payload.count >= 8 else { continue }
                let tab = int32(payload, 0)
                let limit = int32(payload, 4)
                guard var current = tabs[tab] else { continue }
                current.navigations = current.navigations.filter { $0.key < limit }
                tabs[tab] = current
            case 6: // una pagina della cronologia della scheda
                guard let navigation = navigation(payload) else { continue }
                tabs[navigation.tab, default: Tab()].navigations[navigation.index] = (navigation.url, navigation.title)
            case 7: // pagina mostrata dalla scheda
                guard payload.count >= 8 else { continue }
                tabs[int32(payload, 0), default: Tab()].selected = int32(payload, 4)
            case 8: // scheda in primo piano nella finestra
                guard payload.count >= 8 else { continue }
                windows[int32(payload, 0), default: Window()].selectedTab = int32(payload, 4)
            case 9: // tipo di finestra (0 = normale)
                guard payload.count >= 8 else { continue }
                windows[int32(payload, 0), default: Window()].type = int32(payload, 4)
            case 14: // posizione e dimensione della finestra
                guard payload.count >= 20 else { continue }
                let x = Double(int32(payload, 4))
                let y = Double(int32(payload, 8))
                let width = Double(int32(payload, 12))
                let height = Double(int32(payload, 16))
                windows[int32(payload, 0), default: Window()].bounds = CGRect(x: x, y: y, width: width, height: height)
            case 16: // scheda chiusa
                guard payload.count >= 4 else { continue }
                tabs[int32(payload, 0)] = nil
            case 17: // finestra chiusa
                guard payload.count >= 4 else { continue }
                windows[int32(payload, 0)] = nil
            case 24: // cronologia della scheda tagliata in mezzo: tolgo count pagine da index
                guard payload.count >= 12 else { continue }
                let tab = int32(payload, 0)
                let start = int32(payload, 4)
                let count = int32(payload, 8)
                guard var current = tabs[tab], count > 0 else { continue }
                var kept: [Int32: (url: String, title: String)] = [:]
                for (index, value) in current.navigations {
                    if index < start {
                        kept[index] = value
                    } else if index >= start + count {
                        kept[index - count] = value
                    }
                }
                current.navigations = kept
                tabs[tab] = current
            default:
                continue
            }
        }

        var result: [ChromeSessionWindow] = []
        // Tutti i tipi di finestra: anche le app installate da Chrome (per esempio WhatsApp Web).
        for (windowID, window) in windows {
            let windowTabs = tabs.values
                .filter { $0.window == windowID }
                .sorted { $0.index < $1.index }
            var urls: [String] = []
            var titles: [String] = []
            for tab in windowTabs {
                let entry = tab.navigations[tab.selected] ?? tab.navigations.max(by: { $0.key < $1.key })?.value
                guard let entry, !entry.url.isEmpty else { continue }
                urls.append(entry.url)
                titles.append(entry.title)
            }
            guard !urls.isEmpty else { continue }
            let selected = min(max(Int(window.selectedTab), 0), urls.count - 1)
            result.append(ChromeSessionWindow(
                profile: profile, id: windowID, bounds: window.bounds,
                tabs: urls, titles: titles, selectedIndex: selected
            ))
        }
        return result
    }

    /// Una pagina della cronologia: [lunghezza][id scheda][indice][indirizzo][titolo][...].
    private static func navigation(_ payload: [UInt8]) -> (tab: Int32, index: Int32, url: String, title: String)? {
        var reader = PickleReader(bytes: payload, position: 4)
        guard let tab = reader.int32(), let index = reader.int32(),
              let url = reader.string(), let title = reader.string16() else { return nil }
        return (tab, index, url, title)
    }

    fileprivate static func int32(_ bytes: [UInt8], _ offset: Int) -> Int32 {
        guard offset + 4 <= bytes.count else { return 0 }
        var value: UInt32 = UInt32(bytes[offset])
        value |= UInt32(bytes[offset + 1]) << 8
        value |= UInt32(bytes[offset + 2]) << 16
        value |= UInt32(bytes[offset + 3]) << 24
        return Int32(bitPattern: value)
    }

    // MARK: Abbinamento con le finestre aperte

    /// Abbina le finestre di Chrome aperte (titolo, posizione, profilo se noto) a quelle della sessione.
    /// Prima per titolo e posizione; poi per esclusione: se di un profilo resta una sola finestra aperta
    /// e una sola finestra nella sessione, sono la stessa. Restituisce, per posizione nell'elenco, la sessione trovata.
    static func assign(_ windows: [(title: String, frame: CGRect, profile: String?)], sessions: [ChromeSessionWindow]) -> [Int: ChromeSessionWindow] {
        var remaining = sessions
        var result: [Int: ChromeSessionWindow] = [:]
        for (index, window) in windows.enumerated() {
            if let found = match(title: window.title, frame: window.frame, profile: window.profile, in: remaining) {
                result[index] = remaining.remove(at: found)
            }
        }
        var changed = true
        while changed {
            changed = false
            let leftover = windows.indices.filter { result[$0] == nil }
            for index in leftover where result[index] == nil {
                let profile = windows[index].profile
                let open = leftover.filter { result[$0] == nil && windows[$0].profile == profile }
                let candidates = remaining.indices.filter { profile == nil || remaining[$0].profile == profile }
                if open.count == 1, candidates.count == 1 {
                    result[index] = remaining.remove(at: candidates[0])
                    changed = true
                }
            }
        }
        let unmatched = windows.indices.filter { result[$0] == nil }
        if !unmatched.isEmpty {
            var open: [String] = []
            for index in unmatched {
                let window = windows[index]
                open.append("\"" + window.title + "\" " + (window.profile ?? "?") + " " + describe(window.frame))
            }
            var left: [String] = []
            for session in remaining {
                left.append("\"" + session.activeTitle + "\" " + session.profile + " " + describe(session.bounds))
            }
            Log.write("Finestre di Chrome senza schede: " + open.joined(separator: "; ") + ". Sessioni rimaste: " + left.joined(separator: "; "))
        }
        return result
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "?" }
        return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }

    /// Abbina una finestra di Chrome (titolo e posizione) a una finestra della sessione.
    /// Il titolo della finestra è il titolo della scheda in primo piano più il nome del profilo.
    static func match(title: String, frame: CGRect, profile: String?, in sessions: [ChromeSessionWindow]) -> Int? {
        let candidates = sessions.indices.filter { profile == nil || sessions[$0].profile == profile }
        guard !candidates.isEmpty else { return nil }
        func gap(_ index: Int) -> CGFloat {
            guard let bounds = sessions[index].bounds else { return 10_000 }
            return abs(bounds.minX - frame.minX) + abs(bounds.minY - frame.minY)
                + abs(bounds.width - frame.width) + abs(bounds.height - frame.height)
        }
        let sameTitle = candidates.filter { index in
            let pageTitle = sessions[index].activeTitle
            return !title.isEmpty && !pageTitle.isEmpty && (title == pageTitle || title.hasPrefix(pageTitle + " - "))
        }
        if let best = sameTitle.min(by: { gap($0) < gap($1) }) { return best }
        guard let best = candidates.min(by: { gap($0) < gap($1) }) else { return nil }
        return gap(best) < 120 ? best : nil
    }
}

/// Lettura dei dati scritti da Chrome con la sua classe Pickle: interi a 32 bit e stringhe
/// precedute dalla lunghezza, allineate a 4 byte.
private struct PickleReader {
    let bytes: [UInt8]
    var position: Int

    mutating func int32() -> Int32? {
        guard position + 4 <= bytes.count else { return nil }
        let value = ChromeSession.int32(bytes, position)
        position += 4
        return value
    }

    mutating func string() -> String? {
        guard let length = int32(), length >= 0 else { return nil }
        let count = Int(length)
        guard position + count <= bytes.count else { return nil }
        let text = String(decoding: bytes[position..<(position + count)], as: UTF8.self)
        position += PickleReader.aligned(count)
        return text
    }

    mutating func string16() -> String? {
        guard let length = int32(), length >= 0 else { return nil }
        let count = Int(length) * 2
        guard position + count <= bytes.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(Int(length))
        var index = position
        while index + 1 < position + count {
            units.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        position += PickleReader.aligned(count)
        return String(decoding: units, as: UTF16.self)
    }

    static func aligned(_ count: Int) -> Int {
        (count + 3) & ~3
    }
}
