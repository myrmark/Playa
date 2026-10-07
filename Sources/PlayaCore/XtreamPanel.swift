import Foundation

/// The management interface behind playlists from Xtream Codes style providers, whose playlist
/// addresses look like `http://host/get.php?username=…&password=…`. Their M3U files often leave
/// out which channels keep an archive; the panel's channel list says.
public struct XtreamPanel: Sendable {
    let base: URLComponents
    let username: String
    let password: String

    public init?(playlistURL: String) {
        guard var components = URLComponents(string: playlistURL), components.scheme?.hasPrefix("http") == true,
              let items = components.queryItems,
              let username = items.first(where: { $0.name == "username" })?.value, !username.isEmpty,
              let password = items.first(where: { $0.name == "password" })?.value
        else { return nil }
        components.queryItems = nil
        components.fragment = nil
        self.base = components
        self.username = username
        self.password = password
    }

    private func api(_ action: String?) -> URL? {
        var components = base
        components.path = "/player_api.php"
        components.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
            + (action.map { [URLQueryItem(name: "action", value: $0)] } ?? [])
        return components.url
    }

    /// The live channels, with their archive settings.
    public var liveStreamsURL: URL? { api("get_live_streams") }
    /// The account and server details, including the server's time zone.
    public var serverInfoURL: URL? { api(nil) }

    /// The stream number at the end of a channel address: `…/live/user/pass/123.ts` or `…/user/pass/123`.
    public static func streamID(fromStreamURL url: String) -> Int? {
        guard let last = URLComponents(string: url)?.path.split(separator: "/").last else { return nil }
        return Int(last.split(separator: ".").first ?? last)
    }

    /// Days of archive by stream number, for the channels that keep one.
    public static func archiveDays(fromLiveStreams data: Data) -> [Int: Int] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        // Panels send numbers as numbers or as strings, depending on the version.
        func number(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? String { return Int(value) }
            return nil
        }
        var days: [Int: Int] = [:]
        for channel in list where number(channel["tv_archive"]) == 1 {
            guard let id = number(channel["stream_id"]) else { continue }
            days[id] = max(number(channel["tv_archive_duration"]) ?? 1, 1)
        }
        return days
    }

    public static func timeZone(fromServerInfo data: Data) -> String? {
        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = info["server_info"] as? [String: Any],
              let zone = server["timezone"] as? String, TimeZone(identifier: zone) != nil
        else { return nil }
        return zone
    }
}

/// A stretch of a channel's archive. Archives aren't made for jumping about in while they play:
/// the way to another point is to ask for the archive again from there.
public struct Recording: Hashable, Sendable {
    /// The live channel's address.
    public let streamURL: String
    public let catchUp: CatchUp
    public let start: Date
    public let length: TimeInterval

    /// The address that plays the recording from `offset` seconds in. Nil when that point is
    /// outside the recording or hasn't been broadcast yet.
    public func url(from offset: TimeInterval, now: Date = Date()) -> String? {
        let from = start.addingTimeInterval(offset)
        guard offset >= 0, offset < length, from < now.addingTimeInterval(-60) else { return nil }
        return catchUp.url(streamURL: streamURL, start: from, duration: length - offset, now: now)
    }
}

extension Channel {
    /// The recording of `programme` from this channel's archive, as something to play.
    public func archived(_ programme: Programme, catchUp: CatchUp, now: Date = Date()) -> Channel? {
        guard catchUp.covers(programme.start, now: now),
              let url = catchUp.url(streamURL: url, start: programme.start, duration: programme.stop.timeIntervalSince(programme.start), now: now)
        else { return nil }
        // An id of its own, so it never clashes with a channel of the playlist.
        var recording = Channel(
            id: -1 - abs(url.hashValue % 1_000_000_000), name: "\(name) · \(programme.title)", url: url,
            group: group, logo: logo, tvgID: tvgID, kind: .movie
        )
        recording.isArchive = true
        recording.recording = Recording(
            streamURL: self.url, catchUp: catchUp, start: programme.start, length: programme.stop.timeIntervalSince(programme.start)
        )
        return recording
    }

    /// The channel's archive from a time picked by hand, for when the guide has no programme
    /// to go by.
    public func archived(from start: Date, minutes: Int, catchUp: CatchUp, now: Date = Date()) -> Channel? {
        let title = start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return archived(Programme(start: start, stop: start.addingTimeInterval(Double(minutes) * 60), title: title), catchUp: catchUp, now: now)
    }
}
