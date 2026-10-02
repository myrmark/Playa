import Foundation

public struct Programme: Hashable, Sendable {
    public let start: Date
    public let stop: Date
    public let title: String

    public init(start: Date, stop: Date, title: String) {
        self.start = start
        self.stop = stop
        self.title = title
    }
}

public struct Guide: Sendable {
    /// Programmes per lowercased XMLTV channel id, sorted by start time.
    public private(set) var programmes: [String: [Programme]]

    public init(programmes: [String: [Programme]] = [:]) {
        self.programmes = programmes.mapValues { $0.sorted { $0.start < $1.start } }
    }

    public var isEmpty: Bool { programmes.isEmpty }

    /// Programmes on `channelID` that overlap the given time range, in order.
    public func programmes(channelID: String?, from start: Date, to end: Date) -> ArraySlice<Programme> {
        guard let channelID, let list = programmes[channelID.lowercased()] else { return [] }
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].stop <= start { low = middle + 1 } else { high = middle }
        }
        var upper = low
        while upper < list.count, list[upper].start < end { upper += 1 }
        return list[low..<upper]
    }

    public func nowAndNext(channelID: String?, at date: Date) -> (now: Programme?, next: Programme?) {
        guard let channelID, let list = programmes[channelID.lowercased()] else { return (nil, nil) }
        // First programme that hasn't ended yet.
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].stop <= date { low = middle + 1 } else { high = middle }
        }
        guard low < list.count else { return (nil, nil) }
        if list[low].start <= date {
            return (list[low], low + 1 < list.count ? list[low + 1] : nil)
        }
        return (nil, list[low])
    }
}

public enum EPGLocator {
    /// The guide URL for a playlist: the one its header advertises, or for Xtream-style
    /// `get.php?username=…&password=…` playlists the matching `xmltv.php` on the same server.
    public static func guideURL(playlistURL: String, advertised: String?) -> URL? {
        if let advertised, let url = URL(string: advertised.split(separator: ",")[0].trimmingCharacters(in: .whitespaces)),
           url.scheme != nil {
            return url
        }
        guard var components = URLComponents(string: playlistURL),
              components.path.hasSuffix("/get.php"),
              let items = components.queryItems,
              let username = items.first(where: { $0.name == "username" }),
              let password = items.first(where: { $0.name == "password" })
        else { return nil }
        components.path = String(components.path.dropLast("get.php".count)) + "xmltv.php"
        components.queryItems = [username, password]
        return components.url
    }
}

public final class XMLTVParser: NSObject, XMLParserDelegate {
    private let wantedChannels: Set<String>?
    private let keepEndingAfter: Date
    private var programmes: [String: [Programme]] = [:]

    private var currentChannel: String?
    private var currentStart: Date?
    private var currentStop: Date?
    private var currentTitle: String?
    private var isInTitle = false

    /// - Parameters:
    ///   - wantedChannels: lowercased channel ids to keep; nil keeps every channel.
    ///   - keepEndingAfter: programmes that ended before this are dropped.
    public static func parse(stream: InputStream, wantedChannels: Set<String>?, keepEndingAfter: Date) -> Guide {
        let delegate = XMLTVParser(wantedChannels: wantedChannels, keepEndingAfter: keepEndingAfter)
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.parse()
        return Guide(programmes: delegate.programmes)
    }

    private init(wantedChannels: Set<String>?, keepEndingAfter: Date) {
        self.wantedChannels = wantedChannels
        self.keepEndingAfter = keepEndingAfter
    }

    public func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == "programme" {
            currentChannel = nil
            guard let channel = attributes["channel"]?.lowercased(),
                  wantedChannels?.contains(channel) ?? true,
                  let start = attributes["start"].flatMap(Self.date(from:)),
                  let stop = attributes["stop"].flatMap(Self.date(from:)),
                  stop > keepEndingAfter
            else { return }
            currentChannel = channel
            currentStart = start
            currentStop = stop
            currentTitle = nil
        } else if elementName == "title", currentChannel != nil, currentTitle == nil {
            isInTitle = true
            currentTitle = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTitle { currentTitle?.append(string) }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "title" {
            isInTitle = false
        } else if elementName == "programme", let channel = currentChannel, let start = currentStart, let stop = currentStop {
            let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty {
                programmes[channel, default: []].append(Programme(start: start, stop: stop, title: title))
            }
            currentChannel = nil
        }
    }

    /// Parses XMLTV timestamps such as `20261002183000 +0200`. A missing offset means UTC.
    /// Hand-rolled because a guide holds hundreds of thousands of them.
    public static func date(from string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 14 else { return nil }
        func number(at index: Int, length: Int) -> Int? {
            guard index + length <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[index..<index + length] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard var year = number(at: 0, length: 4), let month = number(at: 4, length: 2),
              let day = number(at: 6, length: 2), let hour = number(at: 8, length: 2),
              let minute = number(at: 10, length: 2), let second = number(at: 12, length: 2),
              (1...12).contains(month)
        else { return nil }

        // Days since 1970-01-01 for a proleptic Gregorian date.
        if month <= 2 { year -= 1 }
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        var seconds = days * 86_400 + hour * 3600 + minute * 60 + second

        if let signIndex = bytes[14...].firstIndex(where: { $0 == 43 || $0 == 45 }),
           let offsetHours = number(at: signIndex + 1, length: 2),
           let offsetMinutes = number(at: signIndex + 3, length: 2) {
            let offset = offsetHours * 3600 + offsetMinutes * 60
            seconds -= bytes[signIndex] == 43 ? offset : -offset
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
