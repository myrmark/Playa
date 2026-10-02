import Foundation

public struct SeriesEpisode: Hashable, Sendable {
    public let number: Int
    public let title: String?
    /// `Channel.id` of the stream in the playlist this index was built from.
    public let channelID: Int

    public var label: String {
        if number == 0 { return title ?? "Episode" }
        let prefix = "E" + (number < 10 ? "0" : "") + String(number)
        return title.map { "\(prefix) · \($0)" } ?? "Episode \(number)"
    }
}

public struct SeriesSeason: Hashable, Sendable {
    /// 0 for episodes whose names carry no season/episode numbers.
    public let number: Int
    public let episodes: [SeriesEpisode]

    public var label: String { number == 0 ? "Episodes" : "Season \(number)" }
}

public struct SeriesShow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let group: String
    public let logo: String?
    public let seasons: [SeriesSeason]
    public let episodeCount: Int

    /// Key under which a show is stored among the favourites, next to channel stream URLs.
    public var favouriteKey: String { "show:\(group)/\(name)" }
}

public enum EpisodeName {
    public struct Parsed: Equatable {
        public let show: String
        public let season: Int
        public let episode: Int
        public let title: String?
    }

    /// Recognises `Show - S09E02`, `Show S02E03`, `Show_S02E03_Title` and `Show - 1x07 - Title`.
    public static func parse(_ name: String) -> Parsed? {
        let bytes = Array(name.utf8)
        let count = bytes.count

        func digits(at index: inout Int, max: Int) -> Int? {
            var value = 0
            let start = index
            while index < count, index - start < max, isDigit(bytes[index]) {
                value = value * 10 + Int(bytes[index] - 48)
                index += 1
            }
            return index > start ? value : nil
        }
        func result(showEnd: Int, season: Int, episode: Int, titleStart: Int) -> Parsed? {
            guard titleStart >= count || !isDigit(bytes[titleStart]) else { return nil }
            let show = trimmed(bytes[0..<showEnd])
            guard !show.isEmpty else { return nil }
            let title = trimmed(bytes[min(titleStart, count)...])
            return Parsed(show: show, season: season, episode: episode, title: title.isEmpty ? nil : title)
        }

        var index = 1
        while index < count {
            defer { index += 1 }
            let byte = bytes[index]
            guard isSeparator(bytes[index - 1]) else { continue }
            var cursor = index + 1
            if byte == UInt8(ascii: "S") || byte == UInt8(ascii: "s") {
                guard let season = digits(at: &cursor, max: 3) else { continue }
                if cursor < count, [UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: "_")].contains(bytes[cursor]) { cursor += 1 }
                guard cursor < count, bytes[cursor] == UInt8(ascii: "E") || bytes[cursor] == UInt8(ascii: "e") else { continue }
                cursor += 1
                guard let episode = digits(at: &cursor, max: 4),
                      let parsed = result(showEnd: index, season: season, episode: episode, titleStart: cursor)
                else { continue }
                return parsed
            } else if isDigit(byte), bytes[index - 1] == UInt8(ascii: "_") || bytes[..<index].last(where: { $0 != UInt8(ascii: " ") }) == UInt8(ascii: "-") {
                // "1x07" only counts right after a dash or underscore, so "Top Gear 4x4" stays a title.
                cursor = index
                guard let season = digits(at: &cursor, max: 3),
                      cursor < count, bytes[cursor] == UInt8(ascii: "x") || bytes[cursor] == UInt8(ascii: "X")
                else { continue }
                cursor += 1
                guard let episode = digits(at: &cursor, max: 4),
                      let parsed = result(showEnd: index, season: season, episode: episode, titleStart: cursor)
                else { continue }
                return parsed
            }
        }
        return nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
    }

    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> String {
        var slice = bytes
        func isPadding(_ byte: UInt8) -> Bool { isSeparator(byte) || byte == UInt8(ascii: ":") }
        while let first = slice.first, isPadding(first) { slice = slice.dropFirst() }
        while let last = slice.last, isPadding(last) { slice = slice.dropLast() }
        return String(decoding: slice, as: UTF8.self)
    }
}

public enum SeriesIndex {
    public static let looseShowName = "Other episodes"

    /// Groups a playlist's series episodes into shows and seasons. Episodes whose names
    /// can't be parsed end up in one "Other episodes" show per group.
    public static func build(from channels: [Channel]) -> [SeriesShow] {
        struct Key: Hashable {
            let group: String
            let name: String
        }
        struct Builder {
            let name: String
            let group: String
            let isLoose: Bool
            var logo: String?
            var episodes: [(season: Int, episode: SeriesEpisode)] = []
        }
        var indexByKey: [Key: Int] = [:]
        var builders: [Builder] = []

        for channel in channels where channel.kind == .series {
            let parsed = EpisodeName.parse(channel.name)
            let key = Key(group: channel.group, name: parsed?.show.lowercased() ?? "")
            let index: Int
            if let existing = indexByKey[key] {
                index = existing
            } else {
                index = builders.count
                indexByKey[key] = index
                builders.append(Builder(name: parsed?.show ?? looseShowName, group: channel.group, isLoose: parsed == nil))
            }
            if builders[index].logo == nil, !builders[index].isLoose { builders[index].logo = channel.logo }
            if let parsed {
                builders[index].episodes.append((parsed.season, SeriesEpisode(number: parsed.episode, title: parsed.title, channelID: channel.id)))
            } else {
                builders[index].episodes.append((0, SeriesEpisode(number: 0, title: channel.name, channelID: channel.id)))
            }
        }

        builders.sort { left, right in
            if left.isLoose != right.isLoose { return right.isLoose }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return builders.enumerated().map { id, builder in
            let seasons = Dictionary(grouping: builder.episodes, by: \.season)
                .map { number, entries in
                    SeriesSeason(
                        number: number,
                        episodes: entries.map(\.episode).sorted { ($0.number, $0.channelID) < ($1.number, $1.channelID) }
                    )
                }
                .sorted { $0.number < $1.number }
            return SeriesShow(
                id: id, name: builder.name, group: builder.group, logo: builder.logo,
                seasons: seasons, episodeCount: builder.episodes.count
            )
        }
    }
}
