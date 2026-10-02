import PlayaCore
import SwiftUI

/// Series: pick a group, then a show, then an episode.
struct SeriesBrowser: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        NavigationStack {
            let groups = store.playlist.groupsByKind[.series] ?? []
            Group {
                if groups.isEmpty {
                    PlaylistLoadingView()
                } else {
                    List {
                        NavigationLink(value: ChannelFilter.favourites) {
                            Label("Favourites", systemImage: "star.fill")
                        }
                        ForEach(groups, id: \.self) { group in
                            NavigationLink(group, value: ChannelFilter.group(group))
                        }
                    }
                }
            }
            .navigationTitle("Series")
            .navigationDestination(for: ChannelFilter.self) { filter in
                ShowList(filter: filter)
            }
            .navigationDestination(for: SeriesShow.self) { show in
                EpisodeList(show: show)
            }
        }
    }
}

struct ShowList: View {
    let filter: ChannelFilter
    @EnvironmentObject private var store: PlaylistStore

    private var shows: [SeriesShow] {
        store.playlist.shows.filter { show in
            switch filter {
            case .favourites: store.favourites.contains(show.favouriteKey)
            case .group(let group): show.group == group
            }
        }
    }

    var body: some View {
        let shows = shows
        Group {
            if shows.isEmpty {
                Text(filter == .favourites ? "No favourite shows yet. Hold the select button on a show to add it." : "Nothing in this group.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List(shows) { show in
                    ShowRow(show: show)
                }
            }
        }
        .navigationTitle(filter.title)
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
            Button(store.favourites.contains(show.favouriteKey) ? "Remove from Favourites" : "Add to Favourites") {
                store.toggleFavourite(key: show.favouriteKey)
            }
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
