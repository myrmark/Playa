import Foundation

/// A channel's archive of past programmes, as the playlist describes it: how far back it reaches,
/// and how to ask for a stretch of it.
public struct CatchUp: Hashable, Sendable {
    /// The playlist's `catchup` value, such as "default", "append", "shift", "flussonic" or "xc".
    public let style: String
    /// How many days back programmes can be watched.
    public let days: Int
    /// A template for the archive address, or for what to add to the stream address.
    public let source: String?

    public init(style: String, days: Int, source: String?) {
        self.style = style
        self.days = days
        self.source = source
    }

    /// Reads the attributes of an `#EXTINF` line, falling back to playlist-wide ones from the
    /// `#EXTM3U` line. Nil when the channel has no archive.
    static func parse(_ attributes: [String: String], defaults: [String: String]) -> CatchUp? {
        func value(_ keys: String...) -> String? {
            for key in keys {
                if let value = attributes[key] ?? defaults[key], !value.isEmpty { return value }
            }
            return nil
        }
        let days = value("catchup-days", "tvg-rec").flatMap { Int($0) } ?? 0
        let style = value("catchup", "catchup-type")?.lowercased()
        guard days > 0 || (style != nil && style != "disabled") else { return nil }
        // Some playlists only say how many days are kept; the archive is then the provider's own.
        return CatchUp(style: style ?? "xc", days: max(days, 1), source: value("catchup-source"))
    }

    /// Whether a programme that started at `start` is still in the archive at `now`.
    public func covers(_ start: Date, now: Date = Date()) -> Bool {
        start < now && now.timeIntervalSince(start) < Double(days) * 86_400
    }

    /// The address that plays the archive from `start` for `duration` seconds, or nil when it
    /// can't be worked out from what the playlist gives.
    public func url(streamURL: String, start: Date, duration: TimeInterval, now: Date = Date()) -> String? {
        if let source, style == "default" || style == "append" || source.contains("{") || source.contains("${") {
            let filled = Self.fill(source, start: start, duration: duration, now: now)
            if style == "append" || !(filled.hasPrefix("http://") || filled.hasPrefix("https://")) {
                return streamURL + filled
            }
            return filled
        }
        switch style {
        case "shift", "timeshift":
            let separator = streamURL.contains("?") ? "&" : "?"
            return streamURL + separator + "utc=\(Int(start.timeIntervalSince1970))&lutc=\(Int(now.timeIntervalSince1970))"
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            return Self.flussonic(streamURL, start: start, duration: duration)
        default:
            return Self.xtream(streamURL, start: start, duration: duration)
        }
    }

    /// Xtream Codes panels: `/live/user/pass/123.ts` becomes
    /// `/timeshift/user/pass/<minutes>/<yyyy-MM-dd:HH-mm>/123.ts`.
    static func xtream(_ streamURL: String, start: Date, duration: TimeInterval) -> String? {
        guard var components = URLComponents(string: streamURL) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.first == "live" { parts.removeFirst() }
        guard parts.count == 3 else { return nil }
        let (user, password, file) = (parts[0], parts[1], parts[2])
        let id = file.split(separator: ".").first.map(String.init) ?? file
        guard Int(id) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = max(Int((duration / 60).rounded(.up)), 1)
        components.path = "/timeshift/\(user)/\(password)/\(minutes)/\(formatter.string(from: start))/\(id).ts"
        components.query = nil
        return components.string
    }

    /// Flussonic servers: `.../index.m3u8` becomes `.../index-<start>-<duration>.m3u8`,
    /// `.../mpegts` becomes `.../timeshift_abs-<start>.ts`.
    static func flussonic(_ streamURL: String, start: Date, duration: TimeInterval) -> String? {
        let startValue = Int(start.timeIntervalSince1970)
        let length = Int(duration)
        if let range = streamURL.range(of: #"(index|video)(-[^/?]*)?\.m3u8"#, options: .regularExpression) {
            let name = streamURL[range].hasPrefix("video") ? "video" : "index"
            return streamURL.replacingCharacters(in: range, with: "\(name)-\(startValue)-\(length).m3u8")
        }
        if let range = streamURL.range(of: "/mpegts", options: .backwards) {
            return streamURL.replacingCharacters(in: range, with: "/timeshift_abs-\(startValue).ts")
        }
        return nil
    }

    /// Replaces the placeholders the common players understand: `{utc}`, `{start}`, `{end}`,
    /// `{utcend}`, `{lutc}`, `{now}`, `{duration}`, `{offset}`, `{Y}` `{m}` `{d}` `{H}` `{M}` `{S}`,
    /// and the same in the `${...}` form.
    static func fill(_ template: String, start: Date, duration: TimeInterval, now: Date) -> String {
        let end = start.addingTimeInterval(duration)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let values: [String: String] = [
            "utc": "\(Int(start.timeIntervalSince1970))",
            "start": "\(Int(start.timeIntervalSince1970))",
            "timestamp": "\(Int(start.timeIntervalSince1970))",
            "utcend": "\(Int(end.timeIntervalSince1970))",
            "end": "\(Int(end.timeIntervalSince1970))",
            "lutc": "\(Int(now.timeIntervalSince1970))",
            "now": "\(Int(now.timeIntervalSince1970))",
            "duration": "\(Int(duration))",
            "offset": "\(Int(now.timeIntervalSince(start)))",
            "Y": "\(parts.year ?? 0)", "m": two(parts.month), "d": two(parts.day),
            "H": two(parts.hour), "M": two(parts.minute), "S": two(parts.second),
        ]
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
