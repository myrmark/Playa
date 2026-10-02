import PlayaCore
import SwiftUI

/// Sidebar content for the Series section: a list of shows that drills down into seasons and episodes.
struct SeriesSidebar: View {
    let shows: [SeriesShow]
    /// Changes whenever `shows` does.
    let generation: Int
    let playlist: Playlist
    @ObservedObject var resume: ResumeStore
    let favourites: Set<String>
    @Binding var openShow: SeriesShow?
    @Binding var selection: Channel?
    let toggleFavouriteKey: (String) -> Void
    let toggleFavourite: (Channel) -> Void

    @State private var seasonNumber = 0

    var body: some View {
        if let show = openShow {
            episodes(of: show)
                .onAppear { seasonNumber = startingSeason(of: show) }
                .onChange(of: show) { _, show in seasonNumber = startingSeason(of: show) }
        } else {
            showList
        }
    }

    /// The season of the episode that is playing, otherwise the first one.
    private func startingSeason(of show: SeriesShow) -> Int {
        let playing = show.seasons.first { season in season.episodes.contains { $0.channelID == selection?.id } }
        return (playing ?? show.seasons.first)?.number ?? 0
    }

    private var showList: some View {
        List(shows) { show in
            Button {
                openShow = show
            } label: {
                HStack(spacing: 10) {
                    AsyncImage(url: show.logo.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "play.rectangle.on.rectangle")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 28, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(show.name)
                            .lineLimit(1)
                        Text(summary(of: show))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if favourites.contains(show.favouriteKey) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(favourites.contains(show.favouriteKey) ? "Remove from Favourites" : "Add to Favourites") {
                    toggleFavouriteKey(show.favouriteKey)
                }
            }
        }
        // A fresh list per result set: diffing thousands of rows is far slower than rebuilding.
        .id(generation)
    }

    private func summary(of show: SeriesShow) -> String {
        let episodes = "\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")"
        let numbered = show.seasons.filter { $0.number != 0 }.count
        return numbered > 1 ? "\(numbered) seasons · \(episodes)" : episodes
    }

    private func episodes(of show: SeriesShow) -> some View {
        let season = show.seasons.first { $0.number == seasonNumber } ?? show.seasons.first
        // Channel ids are positions in the playlist the show index was built from.
        let entries = (season?.episodes ?? []).filter { playlist.channels.indices.contains($0.channelID) }
        let labels = Dictionary(entries.map { ($0.channelID, $0.label) }, uniquingKeysWith: { first, _ in first })

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    openShow = nil
                } label: {
                    Label("Shows", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    toggleFavouriteKey(show.favouriteKey)
                } label: {
                    Image(systemName: favourites.contains(show.favouriteKey) ? "star.fill" : "star")
                        .foregroundStyle(favourites.contains(show.favouriteKey) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(favourites.contains(show.favouriteKey) ? "Remove show from Favourites" : "Add show to Favourites")
            }
            .padding(.horizontal, 10)

            Text(show.name)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            if show.seasons.count > 1 {
                Picker("Season", selection: $seasonNumber) {
                    ForEach(show.seasons, id: \.number) { season in
                        Text("\(season.label) (\(season.episodes.count))").tag(season.number)
                    }
                }
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }

            ChannelTable(
                channels: entries.map { playlist.channels[$0.channelID] },
                generation: show.id &* 10_000 &+ (season?.number ?? 0) &+ playlist.channels.count &* 7,
                favourites: favourites,
                guideStamp: resume.version,
                selection: $selection,
                toggleFavourite: toggleFavourite,
                subtitle: { resume.label(for: $0) },
                title: { labels[$0.id] ?? $0.name }
            )
            .padding(.top, 6)
        }
    }
}
