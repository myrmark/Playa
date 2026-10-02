import Foundation

/// A parsed playlist in a compact binary form that loads several times faster than parsing
/// the M3U text again. Used as the on-disk cache between launches.
public enum PlaylistSnapshot {
    /// Bump when the layout below, or anything derived while parsing, changes.
    /// A snapshot with another version is ignored and the playlist is downloaded again.
    public static let formatVersion: UInt32 = 1
    private static let magic: [UInt8] = Array("PLYA".utf8)
    private static let absent = UInt32.max

    public static func encode(_ playlist: Playlist) -> Data {
        var out = Data()
        out.reserveCapacity(playlist.channels.count * 160)

        func number(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        func string(_ value: String?) {
            guard var value else { return number(absent) }
            value.withUTF8 { bytes in
                number(UInt32(bytes.count))
                out.append(bytes)
            }
        }

        out.append(contentsOf: magic)
        number(formatVersion)
        string(playlist.epgURL)

        let groupIndex = Dictionary(playlist.groups.enumerated().map { ($1, UInt32($0)) }, uniquingKeysWith: { first, _ in first })
        number(UInt32(playlist.groups.count))
        playlist.groups.forEach(string)
        for kind in ChannelKind.allCases {
            let groups = playlist.groupsByKind[kind] ?? []
            number(UInt32(groups.count))
            groups.forEach { number(groupIndex[$0] ?? 0) }
        }

        number(UInt32(playlist.channels.count))
        for channel in playlist.channels {
            out.append(UInt8(ChannelKind.allCases.firstIndex(of: channel.kind) ?? 0))
            number(groupIndex[channel.group] ?? 0)
            string(channel.name)
            string(channel.url)
            string(channel.logo)
            string(channel.tvgID)
            string(channel.key)
        }
        return out
    }

    /// Returns nil for data that isn't a snapshot of the current version, or is damaged.
    public static func decode(_ data: Data) -> Playlist? {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Playlist? in
            var offset = 0

            func number() -> UInt32? {
                guard offset + 4 <= bytes.count else { return nil }
                defer { offset += 4 }
                return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            /// `.some(nil)` is a stored nil; plain nil means the data ran out.
            func string() -> String?? {
                guard let length = number() else { return nil }
                if length == absent { return .some(nil) }
                guard offset + Int(length) <= bytes.count else { return nil }
                defer { offset += Int(length) }
                return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + Int(length)]), as: UTF8.self)
            }

            guard bytes.count >= 8, Array(bytes[0..<4]) == magic else { return nil }
            offset = 4
            guard number() == formatVersion, let epgURL = string() else { return nil }

            var playlist = Playlist()
            playlist.epgURL = epgURL
            guard let groupCount = number() else { return nil }
            playlist.groups.reserveCapacity(Int(groupCount))
            for _ in 0..<groupCount {
                guard let group = string() ?? nil else { return nil }
                playlist.groups.append(group)
            }
            for kind in ChannelKind.allCases {
                guard let count = number() else { return nil }
                var groups: [String] = []
                for _ in 0..<count {
                    guard let index = number(), Int(index) < playlist.groups.count else { return nil }
                    groups.append(playlist.groups[Int(index)])
                }
                if !groups.isEmpty { playlist.groupsByKind[kind] = groups }
            }

            guard let channelCount = number() else { return nil }
            playlist.channels.reserveCapacity(Int(channelCount))
            let kinds = ChannelKind.allCases
            var counts = [Int](repeating: 0, count: kinds.count)
            for id in 0..<Int(channelCount) {
                guard offset < bytes.count else { return nil }
                let kindIndex = Int(bytes[offset])
                offset += 1
                guard kindIndex < kinds.count,
                      let group = number(), Int(group) < playlist.groups.count,
                      let name = string() ?? nil, let url = string() ?? nil,
                      let logo = string(), let tvgID = string(), let key = string() ?? nil
                else { return nil }
                counts[kindIndex] += 1
                playlist.channels.append(Channel(
                    id: id, name: name, url: url, group: playlist.groups[Int(group)],
                    logo: logo, tvgID: tvgID, kind: kinds[kindIndex], key: key
                ))
            }
            for (index, count) in counts.enumerated() where count > 0 {
                playlist.countByKind[kinds[index]] = count
            }
            playlist.shows = SeriesIndex.build(from: playlist.channels)
            return playlist
        }
    }
}
