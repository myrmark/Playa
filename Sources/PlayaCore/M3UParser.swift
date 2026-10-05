import CryptoKit
import Foundation

public enum ChannelKind: String, CaseIterable, Hashable, Sendable {
    case live
    case movie
    case series

    private static let fileExtensions = [".mkv", ".mp4", ".avi", ".m4v", ".mpg", ".mov"]

    /// The address without any `?query`, so a file extension is still recognised.
    private static func path(of streamURL: String) -> Substring {
        streamURL.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }

    /// Providers don't label entries, but on-demand streams are files under `/movie/`
    /// or `/series/` (the Xtream layout), while live channels have no file extension.
    public init(streamURL: String) {
        if streamURL.contains("/series/") {
            self = .series
        } else if streamURL.contains("/movie/") || Self.fileExtensions.contains(where: Self.path(of: streamURL).lowercased().hasSuffix) {
            self = .movie
        } else {
            self = .live
        }
    }
}

public struct Channel: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let url: String
    public let group: String
    public let logo: String?
    public let tvgID: String?
    public let kind: ChannelKind
    /// The channel's archive of past programmes, when the playlist offers one.
    public var catchUp: CatchUp?
    /// A recording from a channel's archive rather than the channel itself: not kept in resume
    /// positions or recently watched.
    public var isArchive = false
    /// Stands in for the stream address wherever one is stored or synced (favourites, resume
    /// positions). Stream addresses contain the provider login; this fingerprint does not.
    public let key: String

    public init(id: Int, name: String, url: String, group: String, logo: String?, tvgID: String?, kind: ChannelKind = .live) {
        self.kind = kind
        self.key = Channel.key(forStreamURL: url)
        self.id = id
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo
        self.tvgID = tvgID
    }
}

extension Channel {
    /// For restoring a channel whose key is already known, without hashing its address again.
    init(id: Int, name: String, url: String, group: String, logo: String?, tvgID: String?, kind: ChannelKind, key: String) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo
        self.tvgID = tvgID
        self.kind = kind
        self.key = key
    }

    public static func key(forStreamURL url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return Data(digest.prefix(9)).base64EncodedString()
    }
}

public struct Playlist: Sendable {
    public var channels: [Channel] = []
    /// Groups in the order they first appear in the playlist.
    public var groups: [String] = []
    /// Groups per kind, in the order they first appear.
    public var groupsByKind: [ChannelKind: [String]] = [:]
    public var countByKind: [ChannelKind: Int] = [:]
    /// Series episodes grouped into shows and seasons.
    public var shows: [SeriesShow] = []
    /// XMLTV guide URL advertised in the `#EXTM3U` header, if any.
    public var epgURL: String?

    public init() {}
}

public enum M3UParser {
    public static let ungrouped = "Ungrouped"

    public static func parse(_ text: String) -> Playlist {
        var text = text
        return text.withUTF8(parse(bytes:))
    }

    public static func parse(_ data: Data) -> Playlist {
        data.withUnsafeBytes { parse(bytes: $0.bindMemory(to: UInt8.self)) }
    }

    // Works on raw bytes: provider playlists run to hundreds of thousands of lines,
    // and Character-level scanning made parsing take several seconds.
    private static func parse(bytes: UnsafeBufferPointer<UInt8>) -> Playlist {
        var playlist = Playlist()
        var seenGroups = Set<String>()
        var seenGroupsByKind: [ChannelKind: Set<String>] = [:]
        var pending: (name: String, attributes: [String: String])?
        var pendingGroup: String?
        /// Attributes on the `#EXTM3U` line, which some playlists use as defaults for every channel.
        var headerAttributes: [String: String] = [:]

        let count = bytes.count
        var position = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while position < count {
            var lineEnd = position
            while lineEnd < count, bytes[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
            var start = position
            var end = lineEnd
            position = lineEnd + 1
            while start < end, isWhitespace(bytes[start]) { start += 1 }
            while end > start, isWhitespace(bytes[end - 1]) { end -= 1 }
            if start == end { continue }
            let line = UnsafeBufferPointer(rebasing: bytes[start..<end])

            if line.starts(with: extM3U) {
                let attributes = parseAttributes(line, from: extM3U.count).attributes
                playlist.epgURL = attributes["url-tvg"] ?? attributes["x-tvg-url"]
                headerAttributes = attributes
            } else if line.starts(with: extInf) {
                let parsed = parseAttributes(line, from: extInf.count)
                pending = (parsed.rest, parsed.attributes)
            } else if line.starts(with: extGrp) {
                pendingGroup = string(line, extGrp.count..<line.count).trimmingCharacters(in: .whitespaces)
            } else if line[0] == UInt8(ascii: "#") {
                continue
            } else {
                let url = string(line, 0..<line.count)
                let attributes = pending?.attributes ?? [:]
                let group = nonEmpty(attributes["group-title"]) ?? nonEmpty(pendingGroup) ?? ungrouped
                let name = nonEmpty(pending?.name) ?? nonEmpty(attributes["tvg-name"]) ?? url
                if seenGroups.insert(group).inserted {
                    playlist.groups.append(group)
                }
                let kind = ChannelKind(streamURL: url)
                if seenGroupsByKind[kind, default: []].insert(group).inserted {
                    playlist.groupsByKind[kind, default: []].append(group)
                }
                playlist.countByKind[kind, default: 0] += 1
                playlist.channels.append(Channel(
                    id: playlist.channels.count,
                    name: name,
                    url: url,
                    group: group,
                    logo: nonEmpty(attributes["tvg-logo"]),
                    tvgID: nonEmpty(attributes["tvg-id"]),
                    kind: kind
                ))
                if kind == .live, let catchUp = CatchUp.parse(attributes, defaults: headerAttributes) {
                    playlist.channels[playlist.channels.count - 1].catchUp = catchUp
                }
                pending = nil
                pendingGroup = nil
            }
        }
        playlist.shows = SeriesIndex.build(from: playlist.channels)
        return playlist
    }

    private static let extM3U = Array("#EXTM3U".utf8)
    private static let extInf = Array("#EXTINF:".utf8)
    private static let extGrp = Array("#EXTGRP:".utf8)

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func string(_ line: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: line[range]), as: UTF8.self)
    }

    /// Splits `-1 tvg-id="x" group-title="y",Channel name` into its key="value"
    /// attributes and the text after the first comma outside quotes.
    private static func parseAttributes(
        _ line: UnsafeBufferPointer<UInt8>, from offset: Int
    ) -> (attributes: [String: String], rest: String) {
        var attributes: [String: String] = [:]
        let count = line.count
        var index = offset
        var keyStart: Int?

        while index < count {
            let byte = line[index]
            if byte == UInt8(ascii: ",") {
                return (attributes, string(line, index + 1..<count).trimmingCharacters(in: .whitespaces))
            } else if byte == UInt8(ascii: "="), let start = keyStart {
                let key = string(line, start..<index).lowercased()
                keyStart = nil
                let next = index + 1
                guard next < count, line[next] == UInt8(ascii: "\"") else {
                    index = next
                    continue
                }
                let valueStart = next + 1
                var valueEnd = valueStart
                while valueEnd < count, line[valueEnd] != UInt8(ascii: "\"") { valueEnd += 1 }
                if valueEnd >= count { return (attributes, "") }
                attributes[key] = string(line, valueStart..<valueEnd)
                index = valueEnd + 1
                continue
            } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
                keyStart = nil
            } else if keyStart == nil {
                keyStart = index
            }
            index += 1
        }
        return (attributes, "")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
