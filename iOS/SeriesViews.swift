import PlayaCore
import SwiftUI

/// The shows in Favourites, Recently Watched, a list or a group.
struct ShowListView: View {
    let filter: BrowseFilter
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
                ContentUnavailableView("No shows here yet", systemImage: "play.rectangle.on.rectangle")
            } else {
                List(shows) { show in
                    ShowRow(show: show)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(filter.title(in: store))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ShowRow: View {
    let show: SeriesShow
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        NavigationLink(value: show) {
            HStack(spacing: 12) {
                AsyncImage(url: show.logo.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 32, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(show.name)
                        .lineLimit(1)
                    Text("\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if store.favourites.contains(show.favouriteKey) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.toggleFavourite(key: show.favouriteKey)
            } label: {
                Label("Favourite", systemImage: store.favourites.contains(show.favouriteKey) ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            MembershipMenu(key: show.favouriteKey)
        }
    }
}

struct EpisodeListView: View {
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
                        .contextMenu {
                            MembershipMenu(key: entry.channel.key)
                        }
                    }
                }
            }
        }
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $session) { session in
            PlayerView(session: session)
        }
    }
}
