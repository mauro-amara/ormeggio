import XCTest
@testable import Ormeggio

/// Le scene salvate dalle persone devono restare leggibili dopo ogni aggiornamento.
final class ScenesTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Una scena scritta da una versione vecchia, con i soli campi che c'erano all'inizio.
    func testOldSceneStillLoads() throws {
        let json = """
        {
          "id": "6F1D3E2A-1B2C-4D5E-8F90-1234567890AB",
          "name": "Ufficio",
          "fingerprint": "1234-5678-9+builtin",
          "autoApply": true,
          "displays": [
            { "key": "builtin", "name": "Monitor integrato", "isBuiltin": true,
              "bounds": { "x": 0, "y": 0, "width": 1470, "height": 956 } }
          ],
          "apps": [ { "bundleID": "com.tinyspeck.slackmacgap", "name": "Slack" } ],
          "windows": [
            { "bundleID": "com.tinyspeck.slackmacgap", "appName": "Slack", "title": "",
              "index": 0, "displayKey": "builtin",
              "frame": { "x": 0, "y": 0, "width": 1470, "height": 923 } }
          ],
          "savedAt": "2026-11-20T08:00:00Z"
        }
        """
        let scene = try decoder().decode(SavedScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.name, "Ufficio")
        XCTAssertEqual(scene.windows.count, 1)
        XCTAssertNil(scene.windows[0].desktop)
        XCTAssertNil(scene.displays[0].spaceCount)
        XCTAssertNil(scene.chromeZoom)
    }

    /// Salvare e rileggere una scena completa non perde niente.
    func testSceneRoundTrip() throws {
        var window = SavedWindow(
            bundleID: "com.google.Chrome", appName: "Google Chrome", title: "Posta", index: 0,
            displayKey: "builtin", frame: CodableRect(CGRect(x: 10, y: 20, width: 800, height: 600))
        )
        window.desktop = 2
        window.tabs = ["https://example.com/a"]
        window.chromeProfile = "Profile 1"
        let display = DisplayInfo(
            key: "builtin", name: "Monitor integrato", isBuiltin: true,
            bounds: CodableRect(CGRect(x: 0, y: 0, width: 1470, height: 956)),
            mode: DisplayMode(width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912, refreshRate: 60),
            spaceCount: 3, currentDesktop: 2
        )
        let scene = SavedScene(
            id: UUID(), name: "Casa", fingerprint: "builtin", autoApply: true,
            displays: [display], apps: [SavedApp(bundleID: "com.google.Chrome", name: "Google Chrome")],
            windows: [window], savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            chromeZoom: ["Profile 1": ["example.com": 0.5]], appZoom: nil, icon: "house"
        )
        let data = try encoder().encode([scene])
        let back = try decoder().decode([SavedScene].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].windows[0].desktop, 2)
        XCTAssertEqual(back[0].windows[0].tabs, ["https://example.com/a"])
        XCTAssertEqual(back[0].displays[0].spaceCount, 3)
        XCTAssertEqual(back[0].displays[0].currentDesktop, 2)
        XCTAssertEqual(back[0].chromeZoom?["Profile 1"]?["example.com"], 0.5)
    }
}
