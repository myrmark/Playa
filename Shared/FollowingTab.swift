import PlayaCore
import SwiftUI

/// The Following tab on Apple TV, iPhone and iPad: upcoming broadcasts of what the user follows.
struct FollowingTab: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var following: FollowingStore
    @State private var session: PlayerSession?

    /// Everything a new search depends on.
    private struct Inputs: Hashable {
        let topics: [FollowedTopic]
        let preferences: FollowPreferences
        let guideVersion: Int
        let channelCount: Int
        let favourites: Set<String>
        let lists: [ChannelList]
        let hiddenGroups: Set<String>
    }

    var body: some View {
        NavigationStack {
            let days = Broadcast.byDay(following.broadcasts)
            List {
                Section {
                    NavigationLink {
                        FollowingTopicsView()
                    } label: {
                        Label(topicsSummary, systemImage: "binoculars")
                    }
                }
                ForEach(days, id: \.day) { day in
                    Section(Broadcast.dayTitle(day.day)) {
                        ForEach(day.broadcasts) { broadcast in
                            BroadcastRow(broadcast: broadcast) { index in
                                // The other channels showing it become the next and previous channels.
                                session = PlayerSession(channels: broadcast.channels, index: index)
                            }
                        }
                    }
                }
                if following.broadcasts.isEmpty, !following.isSearching {
                    Section {
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Following")
            .task(id: Inputs(
                topics: following.topics, preferences: following.preferences, guideVersion: epg.version,
                channelCount: store.playlist.channels.count, favourites: store.favourites, lists: store.lists,
                hiddenGroups: store.hiddenGroups
            )) {
                following.search(
                    guide: epg.guide, playlist: store.playlist, favourites: store.favourites, lists: store.lists,
                    hiddenGroups: store.hiddenGroups
                )
            }
            .fullScreenCover(item: $session) { session in
                #if os(tvOS)
                PlayerScreen(session: session)
                #else
                PlayerView(session: session)
                #endif
            }
        }
    }

    private var topicsSummary: String {
        let enabled = following.topics.filter(\.isEnabled).map(\.name)
        if following.topics.isEmpty { return "Choose what to follow" }
        return enabled.isEmpty ? "Nothing selected" : enabled.joined(separator: ", ")
    }

    private var emptyText: String {
        if epg.guide.isEmpty { return "Following needs a playlist with a TV guide." }
        if following.topics.contains(where: \.isEnabled) {
            return "None of the channels in your guide list a matching programme in the coming days. Try adding another spelling as a keyword."
        }
        return "Follow a team, a sport or a show to see when it is on."
    }
}

private struct BroadcastRow: View {
    let broadcast: Broadcast
    /// Called with the position of the chosen channel in `broadcast.channels`.
    let onPlay: (Int) -> Void

    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        Button {
            onPlay(0)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(broadcast.isOnNow(at: Date()) ? "Now" : broadcast.programme.start.formatted(date: .omitted, time: .shortened))
                        .fontWeight(.semibold)
                        .foregroundStyle(broadcast.isOnNow(at: Date()) ? Color.accentColor : Color.primary)
                    Text(broadcast.timeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(broadcast.topics.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(broadcast.programme.title)
                    .lineLimit(1)
                if let description = broadcast.programme.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let best = broadcast.channels.first {
                    Label(
                        broadcast.channels.count > 1 ? "\(best.name) and \(broadcast.channels.count - 1) more" : best.name,
                        systemImage: store.favourites.contains(best.key) ? "star.fill" : "play.fill"
                    )
                    .font(.caption)
                    .lineLimit(1)
                }
            }
        }
        .contextMenu {
            // Any of the channels showing it can be chosen directly.
            ForEach(Array(broadcast.channels.enumerated()), id: \.element.id) { index, channel in
                Button(channel.name) { onPlay(index) }
            }
        }
    }
}

/// Choose what to follow, and how to pick between channels showing the same thing.
struct FollowingTopicsView: View {
    @EnvironmentObject private var following: FollowingStore
    @EnvironmentObject private var store: PlaylistStore
    @State private var languageText = ""

    var body: some View {
        List {
            Section {
                ForEach(following.topics) { topic in
                    Toggle(isOn: Binding(get: { topic.isEnabled }, set: { following.setEnabled($0, for: topic.id) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(topic.name)
                            let details = [topic.keywords.joined(separator: ", "), topic.scopeName(in: store.lists).map { "in \($0)" } ?? ""].filter { !$0.isEmpty }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contextMenu {
                        NavigationLink("Edit") { FollowingTopicForm(topic: topic) }
                        Button("Delete", role: .destructive) { following.delete(topic.id) }
                    }
                }
                NavigationLink {
                    FollowingTopicForm(topic: nil)
                } label: {
                    Label("Follow…", systemImage: "plus")
                }
            } footer: {
                Text("Touch and hold an entry to edit or delete it.")
            }

            Section {
                Toggle("Favourite channels first", isOn: Binding(
                    get: { following.preferences.favouritesFirst },
                    set: { following.setFavouritesFirst($0) }
                ))
                TextField("Preferred languages: SE, EN", text: $languageText)
                    .autocorrectionDisabled()
                    .onSubmit { following.setLanguageTags(languageText) }
            } header: {
                Text("When several channels show it")
            } footer: {
                Text("Languages are the markers in channel names, such as SE, EN or ENG, most wanted first.")
            }
        }
        .navigationTitle("Following")
        .onAppear { languageText = following.preferences.languageTags.joined(separator: ", ") }
        .onDisappear { following.setLanguageTags(languageText) }
    }
}

struct FollowingTopicForm: View {
    let topic: FollowedTopic?

    @EnvironmentObject private var following: FollowingStore
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keywords = ""
    @State private var scope: FollowScope?

    var body: some View {
        Form {
            Section {
                TextField("Name, for example Sweden", text: $name)
                    .autocorrectionDisabled()
                TextField("Other keywords: Sverige, SWE", text: $keywords)
                    .autocorrectionDisabled()
            } footer: {
                Text("Playa looks through the TV guide for programmes that mention the name or any of the other keywords, in their title or description. Separate keywords with commas.")
            }
            Section {
                Picker("Look on", selection: $scope) {
                    Text("All channels").tag(FollowScope?.none)
                    Text("Favourites").tag(FollowScope?.some(.favourites))
                    ForEach(store.lists) { list in
                        Text(list.name).tag(FollowScope?.some(.list(list.id)))
                    }
                }
            } footer: {
                Text("Limiting it to a list, such as your sports channels, keeps out unrelated programmes that happen to mention the name.")
            }
            Section {
                Button(topic == nil ? "Follow" : "Save") {
                    let words = FollowingStore.keywords(from: keywords)
                    if let topic {
                        following.update(topic.id, name: name, keywords: words, scope: scope)
                    } else {
                        following.add(name: name, keywords: words, scope: scope)
                    }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle(topic == nil ? "Follow" : "Edit")
        .onAppear {
            name = topic?.name ?? ""
            keywords = topic?.keywords.joined(separator: ", ") ?? ""
            scope = topic?.scope
        }
    }
}
