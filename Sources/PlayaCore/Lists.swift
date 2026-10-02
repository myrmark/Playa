import Foundation

/// A named, ordered collection of channels, films and shows that the user put together.
/// Members are `Channel.key`s and `SeriesShow.favouriteKey`s, so a list holds no provider login.
public struct ChannelList: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// In the order they were added, unless rearranged.
    public private(set) var keys: [String]

    public init(id: UUID = UUID(), name: String, keys: [String] = []) {
        self.id = id
        self.name = name
        self.keys = keys
    }

    public func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    public mutating func add(_ key: String) {
        if !keys.contains(key) { keys.append(key) }
    }

    public mutating func remove(_ key: String) {
        keys.removeAll { $0 == key }
    }

    /// Moves `key` to sit directly before `other`, or to the end when `other` is nil.
    public mutating func move(_ key: String, before other: String?) {
        guard key != other, let from = keys.firstIndex(of: key) else { return }
        keys.remove(at: from)
        if let other, let to = keys.firstIndex(of: other) {
            keys.insert(key, at: to)
        } else {
            keys.append(key)
        }
    }
}
