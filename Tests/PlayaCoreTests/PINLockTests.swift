import XCTest
@testable import PlayaCore

final class PINLockTests: XCTestCase {
    func testAcceptsOnlyDigitPINsOfSensibleLength() {
        XCTAssertTrue(PINLock.isValid("1234"))
        XCTAssertTrue(PINLock.isValid("12345678"))
        XCTAssertFalse(PINLock.isValid("123"))
        XCTAssertFalse(PINLock.isValid("123456789"))
        XCTAssertFalse(PINLock.isValid("12a4"))
        XCTAssertFalse(PINLock.isValid("١٢٣٤"), "only ASCII digits")
        XCTAssertNil(PINLock(pin: "12"))
    }

    func testVerifiesAndSlowsDownGuessing() throws {
        var lock = try XCTUnwrap(PINLock(pin: "4711"))
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(lock.verify("0000", at: start))
        XCTAssertFalse(lock.verify("1111", at: start))
        XCTAssertEqual(lock.secondsUntilNextAttempt(at: start), 0, "two wrong guesses are free")
        XCTAssertFalse(lock.verify("2222", at: start))
        XCTAssertEqual(lock.secondsUntilNextAttempt(at: start), 30)

        XCTAssertFalse(lock.verify("4711", at: start.addingTimeInterval(10)), "even the right PIN has to wait")
        XCTAssertEqual(lock.failures, 3, "an attempt during the pause isn't counted")

        XCTAssertFalse(lock.verify("3333", at: start.addingTimeInterval(31)))
        XCTAssertEqual(lock.secondsUntilNextAttempt(at: start.addingTimeInterval(31)), 60, "the pause doubles")

        XCTAssertTrue(lock.verify("4711", at: start.addingTimeInterval(100)))
        XCTAssertEqual(lock.failures, 0)
        XCTAssertEqual(lock.secondsUntilNextAttempt(at: start.addingTimeInterval(100)), 0)
    }

    func testStoresNoDigitsAndSurvivesEncoding() throws {
        let lock = try XCTUnwrap(PINLock(pin: "987654"))
        let data = try JSONEncoder().encode(lock)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("987654"))
        var decoded = try JSONDecoder().decode(PINLock.self, from: data)
        XCTAssertTrue(decoded.verify("987654"))
        XCTAssertNotEqual(try JSONEncoder().encode(XCTUnwrap(PINLock(pin: "987654"))), data, "each PIN gets its own salt")
    }
}
