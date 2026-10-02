import PlayaCore
import SwiftUI

/// Series: Favourites, lists and groups on the left, shows on the right, then a show's episodes.
struct SeriesBrowser: View {
    var body: some View {
        NavigationStack {
            TwoPaneBrowser(kind: .series) { filter, focus, wantsFocus in
                ShowPane(filter: filter, focus: focus, wantsFocus: wantsFocus)
            }
            .navigationDestination(for: SeriesShow.self) { show in
                EpisodeList(show: show)
            }
        }
    }
}

struct ShowPane: View {
    let filter: ChannelFilter
    let focus: FocusState<BrowserFocus?>.Binding
    @Binding var wantsFocus: Bool
    @EnvironmentObject private var store: PlaylistStore

    private var shows: [SeriesShow] {
        switch filter {
        case .favourites:
            return store.playlist.shows.filter { store.favourites.contains($0.favouriteKey) }
        case .group(let group):
            return store.playlist.shows.filter { $0.group == group }
        case .list, .recent:
            // Lists and Recently Watched have an order of their own.
            var keys = store.recents
            if case .list(let id) = filter { keys = store.lists.first { $0.id == id }?.keys ?? [] }
            let position = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return store.playlist.shows.filter { position[$0.favouriteKey] != nil }
                .sorted { (position[$0.favouriteKey] ?? 0) < (position[$1.favouriteKey] ?? 0) }
        }
    }

    var body: some View {
        let shows = shows
        Group {
            if shows.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shows) { show in
                    ShowRow(show: show)
                        .focused(focus, equals: .item(show.id))
                }
            }
        }
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: wantsFocus) { takeFocusIfAsked() }
    }

    private func takeFocusIfAsked() {
        guard wantsFocus else { return }
        wantsFocus = false
        if let first = shows.first { focus.wrappedValue = .item(first.id) }
    }

    private var emptyText: String {
        switch filter {
        case .favourites: "No favourite shows yet. Hold the select button on a show to add it."
        case .recent: "No shows watched yet."
        case .list: "This list has no shows yet. Hold the select button on a show to add it."
        case .group: "Nothing in this group."
        }
    }
}

struct ShowRow: View {
    let show: SeriesShow
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        NavigationLink(value: show) {
            HStack(spacing: 24) {
                AsyncImage(url: show.logo.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    Text(show.name)
                        .lineLimit(1)
                    Text("\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if store.favourites.contains(show.favouriteKey) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .contextMenu {
            MembershipMenu(key: show.favouriteKey)
        }
    }
}

struct EpisodeList: View {
    let show: SeriesShow
    @EnvironmentObject private var store: PlaylistStore
    @State private var session: PlayerSession?

    /// The streams of a season, in episode order. Channel ids are positions in the playlist.
    private func channels(of season: SeriesSeason) -> [(episode: SeriesEpisode, channel: Channel)] {
        season.episodes.compactMap { episode in
            store.playlist.channels.indices.contains(episode.channelID)
                ? (episode, store.playlist.channels[episode.channelID]) : nil
        }
    }

    var body: some View {
        List {
            ForEach(show.seasons, id: \.number) { season in
                let entries = channels(of: season)
                Section(season.label) {
                    ForEach(entries, id: \.channel.id) { entry in
                        ChannelRow(channel: entry.channel, title: entry.episode.label, now: Date()) {
                            session = PlayerSession(
                                showKey: show.favouriteKey,
                                channels: entries.map(\.channel),
                                index: entries.firstIndex { $0.channel.id == entry.channel.id } ?? 0
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(show.name)
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
        }
    }
}
