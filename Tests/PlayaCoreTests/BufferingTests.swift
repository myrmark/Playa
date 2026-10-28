import XCTest
@testable import PlayaCore

final class BufferingTests: XCTestCase {
    /// 8 Mbit/s, a typical 1080p channel.
    let needs = 1_000_000.0

    func testFastConnectionBlamesProvider() {
        let reason = BufferingReason.diagnose(check: .speed(bytesPerSecond: 25_000_000), streamArriving: 200_000, streamNeeds: needs)
        XCTAssertEqual(reason, .provider(connectionMbps: 201.6))
    }

    func testSlowConnectionBlamesConnection() {
        let reason = BufferingReason.diagnose(check: .speed(bytesPerSecond: 500_000), streamArriving: 300_000, streamNeeds: needs)
        XCTAssertEqual(reason, .connection(connectionMbps: 6.4, neededMbps: 8))
        XCTAssertEqual(reason?.message, "Your internet connection is too slow right now: 6.4 Mbit/s, and this channel needs about 8.")
    }

    func testStreamShareCountsTowardsConnection() {
        // The check alone is under twice the need, but with the stream's share it is over.
        let reason = BufferingReason.diagnose(check: .speed(bytesPerSecond: 1_500_000), streamArriving: 600_000, streamNeeds: needs)
        XCTAssertEqual(reason, .provider(connectionMbps: 16.8))
    }

    func testUnknownBitrateUsesFixedThresholds() {
        XCTAssertEqual(BufferingReason.diagnose(check: .speed(bytesPerSecond: 5_000_000), streamArriving: 0, streamNeeds: 0),
                       .provider(connectionMbps: 40))
        XCTAssertEqual(BufferingReason.diagnose(check: .speed(bytesPerSecond: 500_000), streamArriving: 0, streamNeeds: 0),
                       .connection(connectionMbps: 4, neededMbps: nil))
        XCTAssertNil(BufferingReason.diagnose(check: .speed(bytesPerSecond: 2_000_000), streamArriving: 0, streamNeeds: 0))
    }

    func testOfflineAndFailedChecks() {
        XCTAssertEqual(BufferingReason.diagnose(check: .offline, streamArriving: 0, streamNeeds: needs), .offline)
        XCTAssertNil(BufferingReason.diagnose(check: .failed, streamArriving: 0, streamNeeds: needs))
    }

    func testMessageRounding() {
        XCTAssertEqual(BufferingReason.provider(connectionMbps: 213.7).message,
                       "The provider is sending this channel slowly. Your internet connection is fine (214 Mbit/s).")
    }
}
