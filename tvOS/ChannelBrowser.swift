import PlayaCore
import SwiftUI

enum ChannelFilter: Hashable {
    case favourites
    case group(String)

    var title: String {
        switch self {
        case .favourites: "Favourites"
        case .group(let name): name
        }
    }
}

/// Live TV or Films: pick a group, then a channel.
struct ChannelBrowser: View {
    let kind: ChannelKind
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        NavigationStack {
            let groups = store.playlist.groupsByKind[kind] ?? []
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
            .navigationTitle(kind.title)
            .navigationDestination(for: ChannelFilter.self) { filter in
                ChannelList(kind: kind, filter: filter)
            }
        }
    }
}

struct ChannelList: View {
    let kind: ChannelKind
    let filter: ChannelFilter

    @EnvironmentObject private var store: PlaylistStore
    @State private var channels: [Channel]?
    @State private var session: PlayerSession?

    var body: some View {
        Group {
            if let channels, channels.isEmpty {
                Text(filter == .favourites ? "No favourites yet. Hold the select button on a channel to add it." : "Nothing in this group.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if let channels {
                // The guide labels follow the clock.
                TimelineView(.everyMinute) { timeline in
                    List(channels) { channel in
                        ChannelRow(channel: channel, now: timeline.date) {
                            session = PlayerSession(channels: channels, index: channels.firstIndex(of: channel) ?? 0)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(filter.title)
        .task(id: store.playlist.channels.count) { await load() }
        .onChange(of: store.favourites) { Task { if filter == .favourites { await load() } } }
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
        }
    }

    private func load() async {
        let playlist = store.playlist, favourites = store.favourites, kind = kind, filter = filter
        channels = await Task.detached(priority: .userInitiated) {
            playlist.channels.filter { channel in
                guard channel.kind == kind else { return false }
                switch filter {
                case .favourites: return favourites.contains(channel.url)
                case .group(let group): return channel.group == group
                }
            }
        }.value
    }
}

struct ChannelRow: View {
    let channel: Channel
    var title: String?
    let now: Date
    let action: () -> Void

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var resume: ResumeStore

    private var subtitle: String? {
        channel.kind == .live
            ? epg.guide.nowAndNext(channelID: channel.tvgID, at: now).now?.title
            : resume.label(for: channel)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                AsyncImage(url: channel.logo.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: channel.kind == .live ? "tv" : "film")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 90, height: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? channel.name)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if store.favourites.contains(channel.url) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .contextMenu {
            Button(store.favourites.contains(channel.url) ? "Remove from Favourites" : "Add to Favourites") {
                store.toggleFavourite(channel)
            }
        }
    }
}
