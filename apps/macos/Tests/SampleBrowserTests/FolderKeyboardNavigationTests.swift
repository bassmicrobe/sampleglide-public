import XCTest
@testable import SampleBrowser

final class FolderKeyboardNavigationTests: XCTestCase {
    func testHoldingAnArrowAtEitherEdgeDoesNotRestartTheSelectedSample() {
        let rows = ["Kick.wav", "Snare.wav", "Hat.wav"]
        XCTAssertNil(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: rows.first, movingDown: false))
        XCTAssertNil(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: rows.last, movingDown: true))
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: "Snare.wav", movingDown: true), "Hat.wav")
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: "Snare.wav", movingDown: false), "Kick.wav")
    }

    func testSearchNavigationUsesOnlyVisibleRowsAndRecoversFromHiddenSelection() {
        let filteredRows = ["Kick 01.wav", "Kick 02.wav"]
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: filteredRows, selectedID: "Snare.wav", movingDown: true), "Kick 01.wav")
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: filteredRows, selectedID: "Snare.wav", movingDown: false), "Kick 02.wav")
        XCTAssertNil(FolderColumnKeyboardNavigation.nextID(in: [], selectedID: "Snare.wav", movingDown: true))
    }

    func testEnteringAnUnselectedColumnCanNavigateInEitherDirection() {
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: ["Drums", "Bass.wav"], selectedID: nil, movingDown: true), "Drums")
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: ["Drums", "Bass.wav"], selectedID: nil, movingDown: false), "Bass.wav")
    }

    func testFavoriteAndAnnotationUUIDRowsUseVisibleOrderWithoutWrappingOrRepeating() {
        let first = UUID(), second = UUID(), hidden = UUID()
        let rows = [first, second]
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: nil, movingDown: true), first)
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: first, movingDown: true), second)
        XCTAssertEqual(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: hidden, movingDown: false), second)
        XCTAssertNil(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: second, movingDown: true))
        XCTAssertNil(FolderColumnKeyboardNavigation.nextID(in: rows, selectedID: first, movingDown: false))
    }
}
