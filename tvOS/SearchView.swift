import PlayaCore
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var text = ""
    @State private var channels: [Channel] = []
    @State private var shows: [SeriesShow] = []
    @State private var session: PlayerSession?

    /// Enough to find anything by typing a little more, without building enormous lists.
    private static let limit = 60

    var body: some View {
        NavigationStack {
            List {
                if !channels.isEmpty {
                    Section("Channels and films") {
                        ForEach(channels) { channel in
                            ChannelRow(channel: channel, now: Date()) {
                                session = PlayerSession(channels: [channel], index: 0)
                            }
                        }
                    }
                }
                if !shows.isEmpty {
                    Section("Series") {
                        ForEach(shows) { show in
                            ShowRow(show: show)
                        }
                    }
                }
            }
            .searchable(text: $text, prompt: "Channels, films and series")
            .navigationDestination(for: SeriesShow.self) { show in
                EpisodeList(show: show)
            }
            .task(id: text) { await search() }
            .fullScreenCover(item: $session) { session in
                PlayerScreen(session: session)
            }
        }
    }

    private func search() async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            channels = []
            shows = []
            return
        }
        // Wait for a pause in typing.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let playlist = store.playlist, limit = Self.limit
        let result = await Task.detached(priority: .userInitiated) { () -> ([Channel], [SeriesShow]) in
            func matches(_ name: String) -> Bool {
                name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            var channels: [Channel] = []
            for channel in playlist.channels where channel.kind != .series && matches(channel.name) {
                channels.append(channel)
                if channels.count == limit { break }
            }
            let shows = Array(playlist.shows.lazy.filter { matches($0.name) }.prefix(limit))
            return (channels, shows)
        }.value
        if Task.isCancelled { return }
        channels = result.0
        shows = result.1
    }
}
