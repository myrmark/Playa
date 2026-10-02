import XCTest
@testable import PlayaCore

final class ResumeTests: XCTestCase {
    func testRecordsAndResumes() {
        var book = ResumeBook()
        XCTAssertNil(book.resumePosition(for: "a"))

        XCTAssertFalse(book.record(key: "a", position: 500, duration: 0), "nothing is recorded before the length is known")
        XCTAssertTrue(book.record(key: "a", position: 500, duration: 6000))
        XCTAssertFalse(book.record(key: "a", position: 510, duration: 6000))
        XCTAssertEqual(book.resumePosition(for: "a"), 510)

        XCTAssertTrue(book.record(key: "a", position: 5800, duration: 6000), "crossing into watched changes the label")
        XCTAssertEqual(book.entry(for: "a")?.isWatched, true)
        XCTAssertNil(book.resumePosition(for: "a"), "a watched film starts over")

        XCTAssertTrue(book.record(key: "a", position: 10, duration: 6000), "rewinding to the start clears the entry")
        XCTAssertNil(book.entry(for: "a"))
        XCTAssertFalse(book.record(key: "a", position: 10, duration: 6000))
    }

    func testMergeKeepsTheNewerEntry() {
        let early = Date(timeIntervalSince1970: 1000), late = Date(timeIntervalSince1970: 2000)
        var mac = ResumeBook(), tv = ResumeBook()
        mac.record(key: "a", position: 100, duration: 6000, at: early)
        mac.record(key: "b", position: 900, duration: 6000, at: late)
        tv.record(key: "a", position: 700, duration: 6000, at: late)
        tv.record(key: "b", position: 50, duration: 6000, at: early)
        tv.record(key: "c", position: 300, duration: 6000, at: early)

        XCTAssertTrue(mac.merge(tv))
        XCTAssertEqual(mac.resumePosition(for: "a"), 700)
        XCTAssertEqual(mac.resumePosition(for: "b"), 900)
        XCTAssertEqual(mac.resumePosition(for: "c"), 300)
        XCTAssertFalse(mac.merge(tv), "merging the same data again changes nothing")

        // Rewinding to the start on one device wins over the other's older position.
        tv.record(key: "a", position: 5, duration: 6000, at: Date(timeIntervalSince1970: 3000))
        XCTAssertTrue(mac.merge(tv))
        XCTAssertNil(mac.resumePosition(for: "a"))

        XCTAssertEqual(Set(mac.newest(2).entries.keys), ["a", "b"])
        XCTAssertEqual(mac.rekeyed { $0 == "c" ? nil : $0 + "!" }.entries.keys.sorted(), ["a!", "b!"])
    }

    func testChannelKeysHideTheAddress() {
        let url = "http://host:80/user/secret/101"
        let key = Channel.key(forStreamURL: url)
        XCTAssertEqual(key.count, 12)
        XCTAssertEqual(key, Channel.key(forStreamURL: url))
        XCTAssertNotEqual(key, Channel.key(forStreamURL: "http://host:80/user/secret/102"))
        XCTAssertFalse(key.contains("secret"))
        XCTAssertEqual(Channel(id: 0, name: "n", url: url, group: "g", logo: nil, tvgID: nil).key, key)
    }

    func testSurvivesEncoding() throws {
        var book = ResumeBook()
        book.record(key: "http://h/movie/u/p/1.mkv", position: 1234, duration: 5000)
        let decoded = try JSONDecoder().decode(ResumeBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(decoded, book)
    }
}
