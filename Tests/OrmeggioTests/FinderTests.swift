import XCTest
@testable import Ormeggio

/// Finestre del Finder di passaggio (il disco dell'installazione): non si salvano e non si riaprono.
@MainActor
final class FinderTests: XCTestCase {
    func testNormalFoldersAreKept() {
        XCTAssertFalse(FinderBridge.isTemporaryVolume("/Users/qualcuno/Documenti"))
        XCTAssertFalse(FinderBridge.isTemporaryVolume("/Applications"))
    }

    func testMissingDiskIsTemporary() {
        XCTAssertTrue(FinderBridge.isTemporaryVolume("/Volumes/Ormeggio-test-\(UUID().uuidString)"))
        XCTAssertTrue(FinderBridge.isTemporaryVolume("/Volumes/Ormeggio-test-\(UUID().uuidString)/cartella"))
    }
}
