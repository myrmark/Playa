import Foundation

/// Where playback of films and episodes stopped, keyed by `Channel.key`.
public struct ResumeBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var position: Double
        public var duration: Double
        /// When this was recorded; decides which device's copy wins when syncing.
        public var updatedAt: Date?

        /// Close enough to the end that the credits are all that's left.
        public var isWatched: Bool { position >= duration * 0.93 }
    }

    /// Stopping this early isn't worth resuming from.
    public static let minimumPosition: Double = 30

    /// Includes entries rewound to the start (position 0): they are kept so that the
    /// rewind reaches other devices instead of being undone by their older copy.
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Where to start from, or nil to start at the beginning.
    public func resumePosition(for key: String) -> Double? {
        guard let entry = entry(for: key), !entry.isWatched else { return nil }
        return entry.position
    }

    public func entry(for key: String) -> Entry? {
        guard let entry = entries[key], entry.position >= Self.minimumPosition else { return nil }
        return entry
    }

    /// Records the current position. Returns true when what a list would show for
    /// this stream changed: it gained or lost an entry, or became watched or unwatched.
    @discardableResult
    public mutating func record(key: String, position: Double, duration: Double, at date: Date = Date()) -> Bool {
        guard duration > 0 else { return false }
        let old = entry(for: key)
        if position < Self.minimumPosition {
            if entries[key] != nil {
                entries[key] = Entry(position: 0, duration: duration, updatedAt: date)
            }
            return old != nil
        }
        let new = Entry(position: position, duration: duration, updatedAt: date)
        entries[key] = new
        return old == nil || old?.isWatched != new.isWatched
    }

    /// Takes every entry from `other` that is newer than this book's. Returns true if anything changed.
    @discardableResult
    public mutating func merge(_ other: ResumeBook) -> Bool {
        var changed = false
        for (key, theirs) in other.entries {
            let mine = entries[key]
            if mine == nil || (theirs.updatedAt ?? .distantPast) > (mine?.updatedAt ?? .distantPast) {
                entries[key] = theirs
                changed = true
            }
        }
        return changed
    }

    /// The most recently updated entries, for storage with a size limit.
    public func newest(_ count: Int) -> ResumeBook {
        guard entries.count > count else { return self }
        var book = ResumeBook()
        let kept = entries.sorted { ($0.value.updatedAt ?? .distantPast) > ($1.value.updatedAt ?? .distantPast) }.prefix(count)
        book.entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        return book
    }

    /// The same entries under new keys. Entries whose key maps to nil are dropped.
    public func rekeyed(_ transform: (String) -> String?) -> ResumeBook {
        var book = ResumeBook()
        for (key, entry) in entries {
            if let newKey = transform(key) { book.entries[newKey] = entry }
        }
        return book
    }
}
