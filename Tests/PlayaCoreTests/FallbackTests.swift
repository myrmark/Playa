import XCTest
@testable import PlayaCore

final class FallbackTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let provider = BufferingReason.provider(connectionMbps: 100)

    func testLongWaitSwitches() {
        XCTAssertTrue(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 11, now: now, reason: provider, checking: false))
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 5, now: now, reason: provider, checking: false))
    }

    func testRepeatedStallsSwitch() {
        let stalls = [now - 100, now - 1]
        XCTAssertTrue(Fallback.shouldSwitch(stallStarts: stalls, waitingSince: now - 1, now: now, reason: provider, checking: false))
        // The first was too long ago to count.
        let spread = [now - 200, now - 1]
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: spread, waitingSince: now - 1, now: now, reason: provider, checking: false))
    }

    func testNothingWhilePlaying() {
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: [now - 30, now - 10], waitingSince: nil, now: now, reason: provider, checking: false))
    }

    func testOwnConnectionNeverSwitches() {
        let slow = BufferingReason.connection(connectionMbps: 3, neededMbps: 8)
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 60, now: now, reason: slow, checking: false))
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 60, now: now, reason: .offline, checking: false))
    }

    func testWaitsForSpeedCheck() {
        XCTAssertFalse(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 11, now: now, reason: nil, checking: true))
        // A check that found nothing either way doesn't hold it back.
        XCTAssertTrue(Fallback.shouldSwitch(stallStarts: [], waitingSince: now - 11, now: now, reason: nil, checking: false))
    }

    func testNextWrapsAndSkipsRecentFailures() {
        let list = ["a", "b", "c"]
        XCTAssertEqual(Fallback.next(after: "a", in: list, failedAt: [:], now: now), "b")
        XCTAssertEqual(Fallback.next(after: "c", in: list, failedAt: [:], now: now), "a")
        XCTAssertEqual(Fallback.next(after: "a", in: list, failedAt: ["b": now - 60], now: now), "c")
        XCTAssertEqual(Fallback.next(after: "a", in: list, failedAt: ["b": now - 700], now: now), "b")
        XCTAssertNil(Fallback.next(after: "a", in: list, failedAt: ["b": now - 60, "c": now - 60], now: now))
        XCTAssertNil(Fallback.next(after: "a", in: ["a"], failedAt: [:], now: now))
    }

    func testOlderListsDecodeWithoutBackups() throws {
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","name":"Old","keys":["x"]}"#
        let list = try JSONDecoder().decode(ChannelList.self, from: Data(json.utf8))
        XCTAssertFalse(list.usesBackups)
    }
}
