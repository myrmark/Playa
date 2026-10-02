import Foundation

/// Text prepared for fast, forgiving matching: lower-cased, accents removed, as raw bytes.
/// Comparing bytes is many times faster than comparing strings with case and accent
/// options, which matters when a guide holds over a hundred thousand programmes.
public struct FoldedText: Sendable {
    public let bytes: [UInt8]

    public init(_ text: String) {
        var text = text
        let ascii = text.withUTF8 { buffer -> [UInt8]? in
            guard buffer.allSatisfy({ $0 < 0x80 }) else { return nil }
            return buffer.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        }
        // Plain ASCII, the common case, only needs lower-casing.
        bytes = ascii ?? Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }
}

/// A word or phrase to look for in programme text. Written in quotes, it only matches as a
/// whole word: "SWE" finds "SWE–NOR" but not "sweet" or "answers".
public struct SearchTerm: Hashable, Sendable {
    public let text: String
    public let wholeWord: Bool
    private let needle: [UInt8]

    private static let quotes: Set<Character> = ["\"", "“", "”", "„", "«", "»"]

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 2, let first = trimmed.first, let last = trimmed.last, Self.quotes.contains(first), Self.quotes.contains(last) {
            text = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            wholeWord = true
        } else {
            text = trimmed
            wholeWord = false
        }
        needle = FoldedText(text).bytes
    }

    public func matches(_ haystack: String) -> Bool {
        matches(FoldedText(haystack))
    }

    public func matches(_ programme: Programme) -> Bool {
        matches(programme.title) || (programme.description.map(matches) ?? false)
    }

    public func matches(_ haystack: FoldedText) -> Bool {
        guard !needle.isEmpty, haystack.bytes.count >= needle.count else { return false }
        return haystack.bytes.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { needle in
                var offset = 0
                while offset + needle.count <= hay.count,
                      let found = memmem(hay.baseAddress! + offset, hay.count - offset, needle.baseAddress!, needle.count) {
                    let position = hay.baseAddress!.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    guard wholeWord else { return true }
                    if !Self.isWordCharacter(endingAt: position, in: hay),
                       !Self.isWordCharacter(startingAt: position + needle.count, in: hay) { return true }
                    offset = position + 1
                }
                return false
            }
        }
    }

    /// Whether the character beginning at `index` is a letter or digit.
    private static func isWordCharacter(startingAt index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        if byte < 0x80 { return (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) }
        // Not ASCII: decode the whole character, since a dash such as "–" is not part of a word.
        let end = min(index + 4, bytes.count)
        let character = String(decoding: UnsafeBufferPointer(rebasing: bytes[index..<end]), as: UTF8.self).first
        return character.map { $0.isLetter || $0.isNumber } ?? false
    }

    /// Whether the character ending just before `index` is a letter or digit.
    private static func isWordCharacter(endingAt index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard index > 0 else { return false }
        var start = index - 1
        // Step back over UTF-8 continuation bytes to the start of the character.
        while start > 0, bytes[start] & 0xC0 == 0x80, index - start < 4 { start -= 1 }
        return isWordCharacter(startingAt: start, in: bytes)
    }
}

/// Which channels a followed topic is looked for on.
public enum FollowScope: Codable, Hashable, Sendable {
    case favourites
    case list(UUID)
}

/// Something the user follows in the TV guide: a team, a sport, a show. Programmes that
/// mention its name or any of its other keywords count as broadcasts of it.
public struct FollowedTopic: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Other spellings and names to look for, such as "Sverige" for "Sweden".
    public var keywords: [String]
    /// Topics can be switched off without deleting them.
    public var isEnabled: Bool
    /// Limits the search to the user's favourites or one of their lists; nil means every channel.
    /// A team name alone matches all sorts of programmes, so narrowing it to, say, a list of
    /// sports channels keeps the results to the point.
    public var scope: FollowScope?

    public init(id: UUID = UUID(), name: String, keywords: [String] = [], isEnabled: Bool = true, scope: FollowScope? = nil) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.scope = scope
    }

    /// Everything a programme is searched for: the name and the keywords.
    public var searchTerms: [String] {
        ([name] + keywords).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// How to choose between several channels showing the same broadcast.
public struct FollowPreferences: Codable, Hashable, Sendable {
    public var favouritesFirst: Bool
    /// Language markers in channel or group names, most wanted first, such as "SE", "EN", "ENG".
    public var languageTags: [String]

    public init(favouritesFirst: Bool = true, languageTags: [String] = []) {
        self.favouritesFirst = favouritesFirst
        self.languageTags = languageTags
    }
}

/// One programme the user follows, with every channel showing it, best choice first.
public struct Broadcast: Identifiable, Sendable {
    public let id: String
    public let programme: Programme
    /// Names of the followed topics it matched.
    public let topics: [String]
    public let channels: [Channel]
}

public enum Following {
    /// Upcoming and running programmes that mention an enabled topic, soonest first. The same
    /// programme on several channels becomes one broadcast listing all of them.
    public static func broadcasts(
        topics: [FollowedTopic], guide: Guide, playlist: Playlist, from date: Date, horizon: TimeInterval,
        favourites: Set<String> = [], lists: [ChannelList] = [], preferences: FollowPreferences = FollowPreferences(),
        hiddenGroups: Set<String> = [], limit: Int = 300
    ) -> [Broadcast] {
        let active = topics.filter { $0.isEnabled && !$0.searchTerms.isEmpty }
        guard !active.isEmpty, !guide.isEmpty else { return [] }

        // The channel keys each topic is limited to; a topic without an entry looks everywhere.
        // A scope naming a list that no longer exists is treated as no limit.
        var allowedKeys: [UUID: Set<String>] = [:]
        for topic in active {
            switch topic.scope {
            case .favourites?: allowedKeys[topic.id] = favourites
            case .list(let id)?: allowedKeys[topic.id] = lists.first { $0.id == id }.map { Set($0.keys) }
            case nil: break
            }
        }

        var channelsByGuideID: [String: [Channel]] = [:]
        for channel in playlist.channels where channel.kind == .live && !hiddenGroups.contains(channel.group) {
            if let id = channel.tvgID { channelsByGuideID[id.lowercased(), default: []].append(channel) }
        }

        let terms = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.searchTerms.map(SearchTerm.init)) })

        struct Found {
            var programme: Programme
            var topics: [String]
            var channels: [Channel]
        }
        var found: [String: Found] = [:]
        let end = date.addingTimeInterval(horizon)
        for (guideID, channels) in channelsByGuideID {
            // Work out once which topics may use these channels at all. A guide channel that
            // no topic is allowed on, typical when topics are limited to a list, is skipped
            // without reading a single programme.
            let candidates: [(topic: FollowedTopic, terms: [SearchTerm], channels: [Channel])] = active.compactMap { topic in
                let allowed = allowedKeys[topic.id].map { keys in channels.filter { keys.contains($0.key) } } ?? channels
                return allowed.isEmpty ? nil : (topic, terms[topic.id] ?? [], allowed)
            }
            guard !candidates.isEmpty else { continue }

            for programme in guide.programmes(channelID: guideID, from: date, to: end) {
                // Each programme's text is prepared once and then checked against every keyword.
                let title = FoldedText(programme.title)
                let description = programme.description.map(FoldedText.init)
                var matched: [String] = []
                var showing: [Channel] = []
                for candidate in candidates where candidate.terms.contains(where: { $0.matches(title) || (description.map($0.matches) ?? false) }) {
                    matched.append(candidate.topic.name)
                    for channel in candidate.channels where !showing.contains(where: { $0.id == channel.id }) { showing.append(channel) }
                }
                guard !matched.isEmpty else { continue }
                // The same event at the same time under the same title is one broadcast.
                let key = "\(Int(programme.start.timeIntervalSince1970 / 60))|\(programme.title.lowercased())"
                if found[key] == nil {
                    found[key] = Found(programme: programme, topics: matched, channels: showing)
                } else {
                    for channel in showing where found[key]?.channels.contains(where: { $0.id == channel.id }) == false {
                        found[key]?.channels.append(channel)
                    }
                    for name in matched where found[key]?.topics.contains(name) == false { found[key]?.topics.append(name) }
                }
            }
        }

        let tags = preferences.languageTags.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        func rank(_ channel: Channel) -> (Int, Int, Int) {
            let favourite = preferences.favouritesFirst && favourites.contains(channel.key) ? 0 : 1
            return (favourite, languageRank(of: channel, tags: tags) ?? Int.max, channel.id)
        }
        return found.map { key, entry in
            Broadcast(id: key, programme: entry.programme, topics: entry.topics, channels: entry.channels.sorted { rank($0) < rank($1) })
        }
        .sorted { ($0.programme.start, $0.id) < ($1.programme.start, $1.id) }
        .prefix(limit)
        .map { $0 }
    }

    /// The position in `tags` of the first language marker found in the channel's name or
    /// group, or nil. A marker has to stand on its own: "SE" matches "SVT1 HD SE" and "SE| SVT1"
    /// but not "Sweden".
    public static func languageRank(of channel: Channel, tags: [String]) -> Int? {
        guard !tags.isEmpty else { return nil }
        let words = Set((channel.name + " " + channel.group).uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return tags.firstIndex(where: words.contains)
    }
}
