import Foundation

/// Why a stream is waiting for data, judged from how fast the internet connection is right now
/// against what the channel needs.
public enum BufferingReason: Equatable, Sendable {
    /// The connection could carry far more than the channel needs, so the provider is sending it slowly.
    case provider(connectionMbps: Double)
    /// The connection is too slow for the channel, or only just fast enough. `neededMbps` is nil
    /// when the channel's bitrate isn't known yet.
    case connection(connectionMbps: Double, neededMbps: Double?)
    /// Nothing could be downloaded at all.
    case offline

    /// What a speed check found.
    public enum Check: Equatable, Sendable {
        case speed(bytesPerSecond: Double)
        case offline
        /// The check itself didn't work (the test server unreachable while other things work, say).
        case failed
    }

    /// - Parameters:
    ///   - check: the speed check, run while the stream was waiting.
    ///   - streamArriving: bytes per second the stream itself was getting during the check.
    ///     The two share the connection, so together they are what it can carry.
    ///   - streamNeeds: the channel's bitrate in bytes per second, or 0 when unknown.
    /// - Returns: nil when the readings don't point either way.
    public static func diagnose(check: Check, streamArriving: Double, streamNeeds: Double) -> BufferingReason? {
        let capacity: Double
        switch check {
        case .offline: return .offline
        case .failed: return nil
        case .speed(let bytesPerSecond): capacity = bytesPerSecond + max(streamArriving, 0)
        }
        let connection = megabits(capacity)
        guard streamNeeds > 0 else {
            // Without the channel's bitrate: a 1080p channel rarely needs more than 10 Mbit/s.
            if connection >= 25 { return .provider(connectionMbps: connection) }
            if connection < 10 { return .connection(connectionMbps: connection, neededMbps: nil) }
            return nil
        }
        // Twice the channel's bitrate leaves room for its peaks and for other traffic at home.
        if capacity >= streamNeeds * 2 { return .provider(connectionMbps: connection) }
        return .connection(connectionMbps: connection, neededMbps: megabits(streamNeeds))
    }

    public var message: String {
        switch self {
        case .provider(let connection):
            "The provider is sending this channel slowly. Your internet connection is fine (\(Self.format(connection)) Mbit/s)."
        case .connection(let connection, let needed?):
            "Your internet connection is too slow right now: \(Self.format(connection)) Mbit/s, and this channel needs about \(Self.format(needed))."
        case .connection(let connection, nil):
            "Your internet connection is slow right now (\(Self.format(connection)) Mbit/s)."
        case .offline:
            "This device seems to have lost its internet connection."
        }
    }

    private static func megabits(_ bytesPerSecond: Double) -> Double { bytesPerSecond * 8 / 1_000_000 }

    /// Whole numbers, with one decimal below 10 where it isn't zero.
    static func format(_ mbps: Double) -> String {
        guard mbps < 10 else { return String(Int(mbps.rounded())) }
        let text = String(format: "%.1f", mbps)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
