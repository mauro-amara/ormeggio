import XCTest
@testable import Ormeggio

/// Riconoscere le finestre di Chrome già aperte: se sbaglia, Ormeggio fa doppioni o perde finestre.
@MainActor
final class MatchingTests: XCTestCase {
    private func session(_ profile: String, _ tabs: [String]) -> ChromeSessionWindow {
        ChromeSessionWindow(profile: profile, id: 1, bounds: nil, tabs: tabs, titles: tabs.map { _ in "" }, selectedIndex: 0)
    }

    private func chromeWindow(profile: String?, tabs: [String]) -> SavedWindow {
        var window = SavedWindow(
            bundleID: BrowserBridge.chromeID, appName: "Google Chrome", title: "", index: 0,
            displayKey: "builtin", frame: CodableRect(CGRect(x: 0, y: 0, width: 800, height: 600))
        )
        window.tabs = tabs
        window.chromeProfile = profile
        return window
    }

    func testPageKeyIgnoresParametersAndAnchors() {
        XCTAssertEqual(Engine.pageKey("https://Mail.Google.com/mail/u/0/?tab=rm#inbox"), "mail.google.com/mail/u/0")
        XCTAssertEqual(Engine.pageKey("https://example.com/"), "example.com")
    }

    func testSimilarTabsScoreHigher() {
        let saved = ["https://a.com/1", "https://b.com/2"]
        let same = Engine.tabSimilarity(saved, ["https://a.com/1", "https://b.com/2"])
        let partial = Engine.tabSimilarity(saved, ["https://a.com/1", "https://c.com/3"])
        let none = Engine.tabSimilarity(saved, ["https://x.com", "https://y.com"])
        XCTAssertGreaterThan(same, partial)
        XCTAssertGreaterThan(partial, none)
        XCTAssertEqual(none, 0)
    }

    /// Una finestra con le stesse schede già aperta: non va riaperta (niente doppioni).
    func testChromeTwinAvoidsDuplicates() {
        let saved = chromeWindow(profile: "Profile 6", tabs: ["https://a.com/1", "https://b.com/2"])
        let open = [session("Profile 6", ["https://a.com/1", "https://b.com/2", "https://c.com"])]
        XCTAssertNotNil(Engine.chromeTwin(of: saved, in: open))
    }

    /// Stesse schede ma in un altro profilo: è un'altra finestra.
    func testChromeTwinRespectsProfiles() {
        let saved = chromeWindow(profile: "Profile 6", tabs: ["https://a.com/1"])
        let open = [session("Profile 1", ["https://a.com/1"])]
        XCTAssertNil(Engine.chromeTwin(of: saved, in: open))
    }

    /// Le riunioni non contano per riconoscere una finestra: una riunione finita non si riapre.
    func testMeetingsDoNotMakeTwins() {
        let saved = chromeWindow(profile: "Profile 6", tabs: ["https://meet.google.com/abc-defg-hij"])
        let open = [session("Profile 6", ["https://meet.google.com/abc-defg-hij"])]
        XCTAssertNil(Engine.chromeTwin(of: saved, in: open))
    }

    func testZoomPercent() {
        XCTAssertEqual(Engine.percent(0), 100)
        XCTAssertEqual(Engine.percent(log(1.1) / log(1.2)), 110)
    }
}
