import Foundation

/// For a list of backup channels: when the channel playing has failed, and which one takes over.
public enum Fallback {
    /// Waiting this long for data in one go counts as failing.
    public static let longWait: TimeInterval = 10
    /// So do this many stalls within `stallWindow`.
    public static let stallLimit = 2
    public static let stallWindow: TimeInterval = 120
    /// A channel that failed is skipped for this long.
    public static let skipFor: TimeInterval = 600

    /// - Parameters:
    ///   - stallStarts: when each stall of the playing stream began (not its first loading).
    ///   - waitingSince: when the current wait for data began, nil while playing.
    ///   - reason: what the speed check found, if it has.
    ///   - checking: whether a speed check is still running; the decision waits for it.
    public static func shouldSwitch(stallStarts: [Date], waitingSince: Date?, now: Date,
                                    reason: BufferingReason?, checking: Bool) -> Bool {
        guard let waitingSince else { return false }
        // Another channel comes over the same connection, so it won't help.
        switch reason {
        case .connection?, .offline?: return false
        case .provider?, nil: break
        }
        if checking { return false }
        if now.timeIntervalSince(waitingSince) >= longWait { return true }
        return stallStarts.filter { now.timeIntervalSince($0) <= stallWindow }.count >= stallLimit
    }

    /// The channel after `current` in list order, wrapping round, that hasn't failed in the last
    /// `skipFor` seconds; nil when every other one has.
    public static func next(after current: String, in candidates: [String], failedAt: [String: Date], now: Date) -> String? {
        guard let start = candidates.firstIndex(of: current) else {
            return candidates.first { !recentlyFailed($0, failedAt, now) }
        }
        for offset in 1..<max(candidates.count, 1) {
            let candidate = candidates[(start + offset) % candidates.count]
            if candidate != current, !recentlyFailed(candidate, failedAt, now) { return candidate }
        }
        return nil
    }

    private static func recentlyFailed(_ key: String, _ failedAt: [String: Date], _ now: Date) -> Bool {
        failedAt[key].map { now.timeIntervalSince($0) < skipFor } ?? false
    }
}
