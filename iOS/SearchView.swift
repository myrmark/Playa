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
                            .contextMenu { MembershipMenu(key: channel.key) }
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
            .listStyle(.plain)
            .overlay {
                if text.trimmingCharacters(in: .whitespaces).count >= 2, channels.isEmpty, shows.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Channels, films and series")
            .navigationDestination(for: SeriesShow.self) { EpisodeListView(show: $0) }
            .task(id: text) { await search() }
            .fullScreenCover(item: $session) { session in
                PlayerView(session: session)
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
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let playlist = store.playlist, limit = Self.limit, hidden = store.hiddenGroups
        let result = await Task.detached(priority: .userInitiated) { () -> ([Channel], [SeriesShow]) in
            func matches(_ name: String) -> Bool {
                name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            func isHidden(_ group: String, _ kind: ChannelKind) -> Bool {
                !hidden.isEmpty && hidden.contains(PlaylistStore.hiddenKey(group: group, kind: kind))
            }
            var channels: [Channel] = []
            for channel in playlist.channels where channel.kind != .series && !isHidden(channel.group, channel.kind) && matches(channel.name) {
                channels.append(channel)
                if channels.count == limit { break }
            }
            let shows = Array(playlist.shows.lazy.filter { !isHidden($0.group, .series) && matches($0.name) }.prefix(limit))
            return (channels, shows)
        }.value
        if Task.isCancelled { return }
        channels = result.0
        shows = result.1
    }
}
