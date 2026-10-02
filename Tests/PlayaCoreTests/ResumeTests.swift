import XCTest
@testable import PlayaCore

final class ResumeTests: XCTestCase {
    func testRecordsAndResumes() {
        var book = ResumeBook()
        XCTAssertNil(book.resumePosition(for: "a"))

        XCTAssertFalse(book.record(url: "a", position: 500, duration: 0), "nothing is recorded before the length is known")
        XCTAssertTrue(book.record(url: "a", position: 500, duration: 6000))
        XCTAssertFalse(book.record(url: "a", position: 510, duration: 6000))
        XCTAssertEqual(book.resumePosition(for: "a"), 510)

        XCTAssertTrue(book.record(url: "a", position: 5800, duration: 6000), "crossing into watched changes the label")
        XCTAssertEqual(book.entry(for: "a")?.isWatched, true)
        XCTAssertNil(book.resumePosition(for: "a"), "a watched film starts over")

        XCTAssertTrue(book.record(url: "a", position: 10, duration: 6000), "rewinding to the start clears the entry")
        XCTAssertNil(book.entry(for: "a"))
        XCTAssertFalse(book.record(url: "a", position: 10, duration: 6000))
    }

    func testSurvivesEncoding() throws {
        var book = ResumeBook()
        book.record(url: "http://h/movie/u/p/1.mkv", position: 1234, duration: 5000)
        let decoded = try JSONDecoder().decode(ResumeBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
    }
}
