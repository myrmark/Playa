import PlayaCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @AppStorage(MPVPlayer.autoReconnectKey) private var autoReconnect = false
    @AppStorage(PlayerView.backgroundSoundKey) private var playsInBackground = true
    @State private var playlistToRemove: SavedPlaylist?

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlists") {
                    ForEach(store.saved) { entry in
                        Button {
                            Task { await store.select(entry.id) }
                        } label: {
                            HStack {
                                Text(entry.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.id == store.activeID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { playlistToRemove = entry }
                        }
                    }
                    NavigationLink("Add Playlist…") { AddPlaylistView() }
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        HStack {
                            Text("Reload Playlist")
                            Spacer()
                            if store.isLoading {
                                Text(store.downloadedBytes.formatted(.byteCount(style: .file)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(store.active == nil || store.isLoading)
                }

                Section {
                    NavigationLink {
                        GroupSettings()
                    } label: {
                        HStack {
                            Text("Groups")
                            Spacer()
                            if !store.hiddenGroups.isEmpty {
                                Text("\(store.hiddenGroups.count) hidden")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent("TV guide", value: guideStatus)
                }

                Section {
                    Toggle("Keep the sound playing when leaving Playa", isOn: $playsInBackground)
                } footer: {
                    Text("The sound carries on when you switch apps or lock the phone, and can be paused from the Lock Screen. The stream is closed if it stays paused in the background for a minute. With this off, leaving Playa closes the stream at once.")
                }

                Section {
                    Toggle("Reconnect automatically when a live channel drops", isOn: $autoReconnect)
                } footer: {
                    Text("Off by default. Many providers allow only one stream per subscription and may ban accounts that open a second one. With this on, Playa can reopen a stream while another device is already watching.")
                }

                PINSettings()

                Section {
                    Link("Privacy Policy", destination: URL(string: "https://github.com/myrmark/Playa/blob/main/PRIVACY.md")!)
                    Link("Source Code", destination: URL(string: "https://github.com/myrmark/Playa")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Playlists, favourites, lists and resume positions sync with Playa on your other devices signed in to the same Apple Account. Playlist addresses, which include your provider login, are stored in iCloud with Apple's standard encryption.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Remove “\(playlistToRemove?.name ?? "")”?",
                isPresented: Binding(get: { playlistToRemove != nil }, set: { if !$0 { playlistToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let id = playlistToRemove?.id { Task { await store.remove(id) } }
                }
            } message: {
                Text("It is removed from your other devices too.")
            }
        }
    }

    private var guideStatus: String {
        switch epg.status {
        case .loading: "Loading…"
        case .loaded: "Loaded"
        case .unavailable: "Not available"
        case .failed: "Unavailable"
        }
    }
}

/// Choose which of the playlist's groups to show.
struct GroupSettings: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var kind = ChannelKind.live
    @State private var searchText = ""

    private var groups: [String] {
        let all = store.playlist.groupsByKind[kind] ?? []
        return searchText.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func isHidden(_ group: String) -> Bool {
        store.hiddenGroups.contains(PlaylistStore.hiddenKey(group: group, kind: kind))
    }

    var body: some View {
        List {
            Section {
                Picker("Section", selection: $kind) {
                    ForEach(ChannelKind.allCases.filter { store.playlist.groupsByKind[$0] != nil }, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Hidden groups disappear from the browser and from search. Channels you put in Favourites or a list stay there. \(groups.filter { !isHidden($0) }.count) of \(groups.count) shown.")
            }
            Section {
                ForEach(groups, id: \.self) { group in
                    Toggle(group, isOn: Binding(
                        get: { !isHidden(group) },
                        set: { store.setHidden(!$0, groups: [group], kind: kind) }
                    ))
                }
            }
        }
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter groups")
        .toolbar {
            // Both act on the groups listed, so a filter narrows what they change.
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Show All") { store.setHidden(false, groups: groups, kind: kind) }
                Spacer()
                Button("Hide All") { store.setHidden(true, groups: groups, kind: kind) }
            }
        }
    }
}

struct AddPlaylistView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""

    var body: some View {
        Form {
            Section {
                TextField("http://provider.example/get.php?…", text: $urlText, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: $name)
            } header: {
                Text("Playlist address")
            } footer: {
                if let error = store.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                } else {
                    Text("Paste the M3U address from your TV provider. Playa contains no channels of its own.")
                }
            }
            Section {
                Button {
                    Task {
                        if await store.add(name: name, url: urlText) { dismiss() }
                    }
                } label: {
                    if store.isLoading {
                        Text("Downloading… \(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                    } else {
                        Text("Add")
                    }
                }
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || store.isLoading)
            }
        }
        .navigationTitle("Add Playlist")
        .onAppear { store.errorMessage = nil }
    }
}
