import XCTest
@testable import PlayaCore

final class ListsTests: XCTestCase {
    func testAddsRemovesAndKeepsOrder() {
        var list = ChannelList(name: "Sport")
        list.add("a")
        list.add("b")
        list.add("a")
        list.add("c")
        XCTAssertEqual(list.keys, ["a", "b", "c"])
        XCTAssertTrue(list.contains("b"))

        list.remove("b")
        XCTAssertEqual(list.keys, ["a", "c"])
        XCTAssertFalse(list.contains("b"))
    }

    func testMoves() {
        var list = ChannelList(name: "Sport", keys: ["a", "b", "c", "d"])
        list.move("d", before: "a")
        XCTAssertEqual(list.keys, ["d", "a", "b", "c"])
        list.move("d", before: "c")
        XCTAssertEqual(list.keys, ["a", "b", "d", "c"])
        list.move("a", before: nil)
        XCTAssertEqual(list.keys, ["b", "d", "c", "a"])

        list.move("b", before: "b")
        list.move("missing", before: "a")
        list.move("c", before: "missing")
        XCTAssertEqual(list.keys, ["b", "d", "a", "c"], "an unknown target means the end")
    }

    func testSurvivesEncoding() throws {
        let list = ChannelList(name: "Kids", keys: ["x", "show:Nordic/Bluey"])
        XCTAssertEqual(try JSONDecoder().decode(ChannelList.self, from: JSONEncoder().encode(list)), list)
    }
}
