import PlayaCore
import SwiftUI

/// Full-window view of the broadcasts of everything the user follows.
struct FollowingView: View {
    @ObservedObject var following: FollowingStore
    let playlist: Playlist
    let guide: Guide
    let guideVersion: Int
    let favourites: Set<String>
    let lists: [ChannelList]
    let hiddenGroups: Set<String>
    let now: Date
    let onPlay: (Channel) -> Void
    let onClose: () -> Void

    @State private var editing: TopicDraft?
    @State private var languageText = ""

    /// Everything a new search depends on.
    private struct Inputs: Hashable {
        let topics: [FollowedTopic]
        let preferences: FollowPreferences
        let guideVersion: Int
        let favourites: Set<String>
        let lists: [ChannelList]
        let hiddenGroups: Set<String>
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                topicList
                    .frame(width: 280)
                Divider()
                broadcastList
            }
        }
        .background(.background)
        .task(id: Inputs(topics: following.topics, preferences: following.preferences, guideVersion: guideVersion, favourites: favourites, lists: lists, hiddenGroups: hiddenGroups)) {
            following.search(guide: guide, playlist: playlist, favourites: favourites, lists: lists, hiddenGroups: hiddenGroups)
        }
        .onAppear { languageText = following.preferences.languageTags.joined(separator: ", ") }
        .sheet(item: $editing) { draft in
            TopicEditor(draft: draft, lists: lists) { name, keywords, scope in
                if let id = draft.existing {
                    following.update(id, name: name, keywords: keywords, scope: scope)
                } else {
                    following.add(name: name, keywords: keywords, scope: scope)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Following")
                .font(.title3.bold())
            Toggle("Favourite channels first", isOn: Binding(
                get: { following.preferences.favouritesFirst },
                set: { following.setFavouritesFirst($0) }
            ))
            Text("Preferred languages")
                .foregroundStyle(.secondary)
            TextField("SE, EN", text: $languageText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit { following.setLanguageTags(languageText) }
                .help("Markers in channel names such as SE, EN or ENG, most wanted first. Press Return to apply.")
            Spacer()
            if following.isSearching {
                ProgressView().controlSize(.small)
            }
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var topicList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(following.topics) { topic in
                    Toggle(isOn: Binding(get: { topic.isEnabled }, set: { following.setEnabled($0, for: topic.id) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topic.name)
                            let details = [topic.keywords.joined(separator: ", "), topic.scopeName(in: lists).map { "in \($0)" } ?? ""].filter { !$0.isEmpty }
                            if !details.isEmpty {
                                Text(details.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Edit…") { editing = TopicDraft(topic) }
                        Button("Delete", role: .destructive) { following.delete(topic.id) }
                    }
                }
            }
            .overlay {
                if following.topics.isEmpty {
                    Text("Follow a team, a sport or a show to see when it is on.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            Divider()
            Button {
                editing = TopicDraft()
            } label: {
                Label("Follow…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private var broadcastList: some View {
        let days = Broadcast.byDay(following.broadcasts)
        return List {
            ForEach(days, id: \.day) { day in
                Section(Broadcast.dayTitle(day.day)) {
                    ForEach(day.broadcasts) { broadcast in
                        BroadcastRow(broadcast: broadcast, now: now, favourites: favourites, onPlay: onPlay)
                    }
                }
            }
        }
        .overlay {
            if following.broadcasts.isEmpty, !following.isSearching {
                if guide.isEmpty {
                    ContentUnavailableView("No TV guide", systemImage: "calendar", description: Text("Following needs a playlist with a TV guide."))
                } else if following.topics.contains(where: \.isEnabled) {
                    ContentUnavailableView("Nothing in the guide", systemImage: "binoculars", description: Text("None of the channels in your guide list a matching programme in the coming days. Try adding another spelling as a keyword."))
                } else {
                    ContentUnavailableView("Nothing followed", systemImage: "binoculars", description: Text("Add something to follow on the left, or tick one you already have."))
                }
            }
        }
    }
}

private struct BroadcastRow: View {
    let broadcast: Broadcast
    let now: Date
    let favourites: Set<String>
    let onPlay: (Channel) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(broadcast.isOnNow(at: now) ? "Now" : broadcast.programme.start.formatted(date: .omitted, time: .shortened))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(broadcast.isOnNow(at: now) ? Color.accentColor : Color.primary)
                Text(broadcast.timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(broadcast.programme.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let description = broadcast.programme.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(broadcast.topics.joined(separator: " · "))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 8)

            if let best = broadcast.channels.first {
                HStack(spacing: 4) {
                    Button {
                        onPlay(best)
                    } label: {
                        Label(best.name, systemImage: favourites.contains(best.key) ? "star.fill" : "play.fill")
                            .lineLimit(1)
                    }
                    .help("Play on \(best.name)")
                    if broadcast.channels.count > 1 {
                        Menu {
                            ForEach(broadcast.channels) { channel in
                                Button {
                                    onPlay(channel)
                                } label: {
                                    if favourites.contains(channel.key) { Label(channel.name, systemImage: "star.fill") } else { Text(channel.name) }
                                }
                            }
                        } label: {
                            Text("+\(broadcast.channels.count - 1)")
                        }
                        .fixedSize()
                        .help("Other channels showing this")
                    }
                }
                .frame(maxWidth: 300, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }
}

/// What the add/edit sheet is working on.
struct TopicDraft: Identifiable {
    let id = UUID()
    var existing: UUID?
    var name = ""
    var keywords = ""
    var scope: FollowScope?

    init() {}

    init(_ topic: FollowedTopic) {
        existing = topic.id
        name = topic.name
        keywords = topic.keywords.joined(separator: ", ")
        scope = topic.scope
    }
}

private struct TopicEditor: View {
    let draft: TopicDraft
    let lists: [ChannelList]
    let onSave: (String, [String], FollowScope?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keywords = ""
    @State private var scope: FollowScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.existing == nil ? "Follow" : "Edit")
                .font(.headline)
            Text("Playa looks through the TV guide for programmes that mention the name or any of the other keywords, in their title or description. Put a keyword in quotes to match it only as a whole word: \"SWE\" finds SWE–NOR but not sweet or answers.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name, for example Sweden", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Other keywords, separated by commas: Sverige, \"SWE\"", text: $keywords)
                .textFieldStyle(.roundedBorder)
            Picker("Look on", selection: $scope) {
                Text("All channels").tag(FollowScope?.none)
                Label("Favourites", systemImage: "star.fill").tag(FollowScope?.some(.favourites))
                ForEach(lists) { list in
                    Label(list.name, systemImage: "list.bullet").tag(FollowScope?.some(.list(list.id)))
                }
            }
            Text("Limiting it to a list, such as your sports channels, keeps out unrelated programmes that happen to mention the name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.existing == nil ? "Follow" : "Save") {
                    onSave(name, FollowingStore.keywords(from: keywords), scope)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = draft.name
            keywords = draft.keywords
            scope = draft.scope
        }
    }
}
