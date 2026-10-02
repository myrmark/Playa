import CryptoKit
import Foundation

/// A PIN kept as a salted hash, never as the digits themselves, plus the bookkeeping that
/// slows down guessing.
public struct PINLock: Codable, Equatable, Sendable {
    private let salt: Data
    private let hash: Data
    /// Wrong attempts since the last correct one.
    public private(set) var failures = 0
    /// While this is in the future, no attempt is accepted.
    public private(set) var lockedUntil: Date?

    /// Wrong guesses allowed before a pause is imposed.
    public static let freeAttempts = 3

    /// PINs are 4 to 8 digits.
    public static func isValid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Returns nil if `pin` isn't a valid PIN.
    public init?(pin: String) {
        guard Self.isValid(pin) else { return nil }
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        self.salt = salt
        self.hash = Self.digest(pin, salt: salt)
    }

    private static func digest(_ pin: String, salt: Data) -> Data {
        // Stretched a little: a four-digit PIN has few possibilities, so each try should cost something.
        var value = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        for _ in 0..<20_000 { value = Data(SHA256.hash(data: value + salt)) }
        return value
    }

    /// Seconds to wait before another attempt is accepted, or 0.
    public func secondsUntilNextAttempt(at date: Date = Date()) -> Int {
        guard let lockedUntil, lockedUntil > date else { return 0 }
        return Int(lockedUntil.timeIntervalSince(date).rounded(.up))
    }

    /// Checks `pin`. After a few wrong guesses each further one adds a longer pause:
    /// 30 seconds, then 1, 2, 4 minutes and so on, up to an hour.
    public mutating func verify(_ pin: String, at date: Date = Date()) -> Bool {
        guard secondsUntilNextAttempt(at: date) == 0 else { return false }
        if Self.digest(pin, salt: salt) == hash {
            failures = 0
            lockedUntil = nil
            return true
        }
        failures += 1
        if failures >= Self.freeAttempts {
            let pause = min(30 * pow(2, Double(failures - Self.freeAttempts)), 3600)
            lockedUntil = date.addingTimeInterval(pause)
        }
        return false
    }
}
