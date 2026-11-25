import XCTest
@testable import Ormeggio

/// Indirizzi, siti e zoom di Chrome: quello che finisce nel browser e negli script deve restare sicuro e giusto.
@MainActor
final class BrowserTests: XCTestCase {
    func testOnlyWebAddressesReachTheBrowser() {
        let input = [
            "https://example.com/a",
            "http://example.org",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "--incognito",
            "chrome://settings",
            "not an address"
        ]
        XCTAssertEqual(BrowserBridge.webAddresses(input), ["https://example.com/a", "http://example.org"])
    }

    func testPlainHosts() {
        XCTAssertTrue(BrowserBridge.isPlainHost("calendar.google.com"))
        XCTAssertTrue(BrowserBridge.isPlainHost("gitlab.example-company.it"))
        XCTAssertFalse(BrowserBridge.isPlainHost(""))
        XCTAssertFalse(BrowserBridge.isPlainHost("localhost"))
        XCTAssertFalse(BrowserBridge.isPlainHost(".example.com"))
        XCTAssertFalse(BrowserBridge.isPlainHost("example.com\" & do shell script \"x"))
        XCTAssertFalse(BrowserBridge.isPlainHost("example.com/path"))
        XCTAssertFalse(BrowserBridge.isPlainHost("exa mple.com"))
    }

    func testZoomAddressIsHttpsOnTheSameSite() {
        let address = BrowserBridge.zoomAddress("Calendar.Google.com")
        XCTAssertEqual(address, "https://calendar.google.com/robots.txt")
        XCTAssertEqual(BrowserBridge.host(of: address), "calendar.google.com")
    }

    func testChromeZoomSteps() {
        // Livelli di Chrome: percentuale = 1,2 elevato al livello.
        func level(_ percent: Double) -> Double { log(percent / 100) / log(1.2) }
        XCTAssertEqual(BrowserBridge.chromeSteps(from: 0, to: 0), 0)
        XCTAssertEqual(BrowserBridge.chromeSteps(from: 0, to: level(110)), 1)
        XCTAssertEqual(BrowserBridge.chromeSteps(from: 0, to: level(125)), 2)
        XCTAssertEqual(BrowserBridge.chromeSteps(from: 0, to: level(90)), -1)
        XCTAssertEqual(BrowserBridge.chromeSteps(from: level(110), to: level(110)), 0)
    }

    func testMeetingsAreRecognised() {
        XCTAssertTrue(BrowserBridge.isMeeting("https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(BrowserBridge.isMeeting("https://us02web.zoom.us/j/123"))
        XCTAssertFalse(BrowserBridge.isMeeting("https://calendar.google.com"))
    }
}
