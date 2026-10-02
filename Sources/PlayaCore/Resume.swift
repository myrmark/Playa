import Foundation

/// Where playback of films and episodes stopped, keyed by stream URL.
public struct ResumeBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var position: Double
        public var duration: Double

        /// Close enough to the end that the credits are all that's left.
        public var isWatched: Bool { position >= duration * 0.93 }
    }

    /// Stopping this early isn't worth resuming from.
    public static let minimumPosition: Double = 30

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Where to start `url` from, or nil to start at the beginning.
    public func resumePosition(for url: String) -> Double? {
        guard let entry = entries[url], !entry.isWatched else { return nil }
        return entry.position
    }

    public func entry(for url: String) -> Entry? {
        entries[url]
    }

    /// Records the current position. Returns true when what a list would show for
    /// this stream changed: it gained or lost an entry, or became watched or unwatched.
    @discardableResult
    public mutating func record(url: String, position: Double, duration: Double) -> Bool {
        guard duration > 0 else { return false }
        let old = entries[url]
        if position < Self.minimumPosition {
            entries[url] = nil
            return old != nil
        }
        let new = Entry(position: position, duration: duration)
        entries[url] = new
        return old == nil || old?.isWatched != new.isWatched
    }
}
