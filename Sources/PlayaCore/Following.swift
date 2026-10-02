import Foundation

/// Something the user follows in the TV guide: a team, a sport, a show. Programmes that
/// mention its name or any of its other keywords count as broadcasts of it.
public struct FollowedTopic: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Other spellings and names to look for, such as "Sverige" for "Sweden".
    public var keywords: [String]
    /// Topics can be switched off without deleting them.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, keywords: [String] = [], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.isEnabled = isEnabled
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
        favourites: Set<String> = [], preferences: FollowPreferences = FollowPreferences(),
        hiddenGroups: Set<String> = [], limit: Int = 300
    ) -> [Broadcast] {
        let active = topics.filter { $0.isEnabled && !$0.searchTerms.isEmpty }
        guard !active.isEmpty, !guide.isEmpty else { return [] }

        var channelsByGuideID: [String: [Channel]] = [:]
        for channel in playlist.channels where channel.kind == .live && !hiddenGroups.contains(channel.group) {
            if let id = channel.tvgID { channelsByGuideID[id.lowercased(), default: []].append(channel) }
        }

        func mentions(_ programme: Programme, _ term: String) -> Bool {
            programme.title.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || programme.description?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        struct Found {
            var programme: Programme
            var topics: [String]
            var channels: [Channel]
        }
        var found: [String: Found] = [:]
        let end = date.addingTimeInterval(horizon)
        for (guideID, channels) in channelsByGuideID {
            for programme in guide.programmes(channelID: guideID, from: date, to: end) {
                let matched = active.filter { topic in topic.searchTerms.contains { mentions(programme, $0) } }.map(\.name)
                guard !matched.isEmpty else { continue }
                // The same event at the same time under the same title is one broadcast.
                let key = "\(Int(programme.start.timeIntervalSince1970 / 60))|\(programme.title.lowercased())"
                if found[key] == nil {
                    found[key] = Found(programme: programme, topics: matched, channels: channels)
                } else {
                    found[key]?.channels += channels
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
