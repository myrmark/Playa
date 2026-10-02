import Foundation

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
                var matched: [String] = []
                var showing: [Channel] = []
                for topic in active where topic.searchTerms.contains(where: { mentions(programme, $0) }) {
                    // Only the channels this topic is allowed on count for it.
                    let allowed = allowedKeys[topic.id].map { keys in channels.filter { keys.contains($0.key) } } ?? channels
                    guard !allowed.isEmpty else { continue }
                    matched.append(topic.name)
                    for channel in allowed where !showing.contains(where: { $0.id == channel.id }) { showing.append(channel) }
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
