import Foundation
import CoreGraphics

/// Rettangolo serializzabile (coordinate globali di macOS, origine in alto a sinistra).
struct CodableRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Risoluzione di un monitor: punti (la "scala" vista dall'utente) e pixel reali.
struct DisplayMode: Codable, Equatable {
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Double

    func sameResolution(as other: DisplayMode) -> Bool {
        width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }

    var label: String { "\(width) × \(height)" }
}

/// Un monitor come era al momento del salvataggio della scena.
struct DisplayInfo: Codable {
    var key: String
    var name: String
    var isBuiltin: Bool
    var bounds: CodableRect
    var mode: DisplayMode?
    var spaceCount: Int?
    /// Scrivania visibile al momento del salvataggio (da 1).
    var currentDesktop: Int?
}

/// Un'app aperta al momento del salvataggio.
struct SavedApp: Codable {
    var bundleID: String
    var name: String
}

/// Una finestra: app, titolo, monitor e posizione relativa al monitor.
struct SavedWindow: Codable {
    var bundleID: String
    var appName: String
    var title: String
    var index: Int
    var displayKey: String
    var frame: CodableRect
    /// Solo per il Finder: la cartella mostrata dalla finestra.
    var folderPath: String?
    /// Scrivania del monitor (da 1). Nil se la finestra è su tutte le scrivanie o non si sa.
    var desktop: Int?
    /// Identificativo della finestra in macOS: vale finché la finestra resta aperta.
    var windowID: UInt32?
    /// Documento aperto nella finestra, se l'app lo dichiara.
    var documentURL: String?
    /// Schede aperte (Chrome e Safari).
    var tabs: [String]?
    /// Cartella del profilo Chrome (per esempio "Default" o "Profile 1").
    var chromeProfile: String?
    /// Ridotta nel Dock al momento del salvataggio.
    var minimized: Bool?
    /// A tutto schermo al momento del salvataggio.
    var fullScreen: Bool?
}

/// Una scena: tutto quello che serve per rimettere il Mac com'era.
struct SavedScene: Codable, Identifiable {
    var id: UUID
    var name: String
    var fingerprint: String
    var autoApply: Bool
    var displays: [DisplayInfo]
    var apps: [SavedApp]
    var windows: [SavedWindow]
    var savedAt: Date
    /// Zoom di Chrome per profilo e sito, letto dalle preferenze di Chrome (livelli di Chrome).
    var chromeZoom: [String: [String: Double]]?
    /// Zoom delle altre app scelto dall'utente: scatti rispetto al 100% (0 = normale).
    var appZoom: [String: Int]?
    /// Icona scelta dall'utente (nome di un simbolo di sistema).
    var icon: String?
}

extension Array {
    /// L'elemento in quella posizione, o nil se la posizione non esiste.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
