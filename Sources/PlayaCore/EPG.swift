import Foundation

public struct Programme: Hashable, Sendable {
    public let start: Date
    public let stop: Date
    public let title: String
    /// What the programme is about, when the guide says.
    public let description: String?

    public init(start: Date, stop: Date, title: String, description: String? = nil) {
        self.start = start
        self.stop = stop
        self.title = title
        self.description = description
    }
}

extension Programme {
    /// How a search result describes this programme: "Now · Title", "20:45 · Title" for later
    /// today, or "Sat 20:45 · Title" for another day.
    public func searchLabel(at date: Date, calendar: Calendar = .current) -> String {
        if start <= date { return "Now · \(title)" }
        let time = start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(start, inSameDayAs: date) { return "\(time) · \(title)" }
        return "\(start.formatted(.dateTime.weekday(.abbreviated))) \(time) · \(title)"
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

    /// For each channel, the first programme that is on at `date` or starts within `horizon`
    /// after it and mentions `query` in its title or description.
    public func search(_ query: String, from date: Date, horizon: TimeInterval) -> [String: Programme] {
        let end = date.addingTimeInterval(horizon)
        // In quotes, the query only matches as a whole word.
        let term = SearchTerm(query)
        var hits: [String: Programme] = [:]
        for (channelID, _) in programmes {
            if let match = programmes(channelID: channelID, from: date, to: end).first(where: term.matches) {
                hits[channelID] = match
            }
        }
        return hits
    }

    /// The live channels showing a programme that matches `query`, soonest first: what is on
    /// now, then what starts later. Channels in `hiddenGroups` are left out.
    public func channels(
        showing query: String, in playlist: Playlist, from date: Date, horizon: TimeInterval = 36 * 3600,
        hiddenGroups: Set<String> = []
    ) -> [(channel: Channel, programme: Programme)] {
        let hits = search(query, from: date, horizon: horizon)
        guard !hits.isEmpty else { return [] }
        var found: [(channel: Channel, programme: Programme)] = []
        for channel in playlist.channels where channel.kind == .live && !hiddenGroups.contains(channel.group) {
            if let id = channel.tvgID, let programme = hits[id.lowercased()] {
                found.append((channel, programme))
            }
        }
        // Programmes already running sort by their start too, which puts them ahead of later ones.
        return found.sorted { ($0.programme.start, $0.channel.id) < ($1.programme.start, $1.channel.id) }
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

/// What a guide file held, for saying why one was of no use.
public struct GuideReport: Equatable, Sendable {
    /// Every programme in the file, on any channel.
    public var programmes = 0
    /// Those on the wanted channels, whenever they are.
    public var onWantedChannels = 0
    /// When the last of those ends.
    public var lastStop: Date?
    /// The line the file stops being readable XML at, if it does.
    public var brokenAtLine: Int?

    public init() {}

    /// Why a guide that gave no programmes didn't.
    public var problem: String {
        var text: String
        if programmes == 0 {
            text = "The guide the provider sent has no programmes."
        } else if onWantedChannels == 0 {
            text = "The guide the provider sent has \(programmes) programmes, none for this playlist's channels."
        } else if let lastStop {
            text = "The guide the provider sent is out of date: it ends \(lastStop.formatted(date: .abbreviated, time: .shortened))."
        } else {
            text = "The guide the provider sent has no programmes for this playlist's channels."
        }
        if let brokenAtLine { text += " The file is broken at line \(brokenAtLine)." }
        return text
    }
}

public final class XMLTVParser: NSObject, XMLParserDelegate {
    private var report = GuideReport()
    private let wantedChannels: Set<String>?
    private let keepEndingAfter: Date
    /// Earlier cut-offs for some channels, such as those with an archive to watch from.
    private let keepPast: [String: Date]
    private var programmes: [String: [Programme]] = [:]

    private var currentChannel: String?
    private var currentStart: Date?
    private var currentStop: Date?
    private var currentTitle: String?
    private var isInTitle = false
    private var currentDescription: String?
    private var isInDescription = false

    /// - Parameters:
    ///   - wantedChannels: lowercased channel ids to keep; nil keeps every channel.
    ///   - keepEndingAfter: programmes that ended before this are dropped.
    ///   - keepPast: for these lowercased channel ids, programmes are kept back to the given date instead.
    public static func parse(stream: InputStream, wantedChannels: Set<String>?, keepEndingAfter: Date, keepPast: [String: Date] = [:]) -> Guide {
        read(stream: stream, wantedChannels: wantedChannels, keepEndingAfter: keepEndingAfter, keepPast: keepPast).guide
    }

    /// As `parse`, and also tells what the file held.
    public static func read(
        stream: InputStream, wantedChannels: Set<String>?, keepEndingAfter: Date, keepPast: [String: Date] = [:]
    ) -> (guide: Guide, report: GuideReport) {
        let delegate = XMLTVParser(wantedChannels: wantedChannels, keepEndingAfter: keepEndingAfter, keepPast: keepPast)
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        if !parser.parse() { delegate.report.brokenAtLine = parser.lineNumber }
        return (Guide(programmes: delegate.programmes), delegate.report)
    }

    private init(wantedChannels: Set<String>?, keepEndingAfter: Date, keepPast: [String: Date]) {
        self.wantedChannels = wantedChannels
        self.keepEndingAfter = keepEndingAfter
        self.keepPast = keepPast
    }

    public func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if elementName == "programme" {
            currentChannel = nil
            report.programmes += 1
            guard let channel = attributes["channel"]?.lowercased(),
                  wantedChannels?.contains(channel) ?? true
            else { return }
            report.onWantedChannels += 1
            guard let start = attributes["start"].flatMap(Self.date(from:)),
                  let stop = attributes["stop"].flatMap(Self.date(from:))
            else { return }
            report.lastStop = max(report.lastStop ?? stop, stop)
            guard stop > (keepPast[channel] ?? keepEndingAfter) else { return }
            currentChannel = channel
            currentStart = start
            currentStop = stop
            currentTitle = nil
            currentDescription = nil
        } else if elementName == "title", currentChannel != nil, currentTitle == nil {
            isInTitle = true
            currentTitle = ""
        } else if elementName == "desc", currentChannel != nil, currentDescription == nil {
            isInDescription = true
            currentDescription = ""
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTitle { currentTitle?.append(string) }
        if isInDescription { currentDescription?.append(string) }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "title" {
            isInTitle = false
        } else if elementName == "desc" {
            isInDescription = false
        } else if elementName == "programme", let channel = currentChannel, let start = currentStart, let stop = currentStop {
            let title = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty {
                let description = currentDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                programmes[channel, default: []].append(Programme(
                    start: start, stop: stop, title: title,
                    description: description?.isEmpty == false ? description : nil
                ))
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
