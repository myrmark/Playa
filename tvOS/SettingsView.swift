import PlayaCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @AppStorage(MPVPlayer.autoReconnectKey) private var autoReconnect = false
    @AppStorage(PlayerScreen.panelOpacityKey) private var panelOpacity = PlayerScreen.defaultPanelOpacity
    @State private var playlistToRemove: SavedPlaylist?

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    ForEach(store.saved) { entry in
                        Button {
                            Task { await store.select(entry.id) }
                        } label: {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                if entry.id == store.activeID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) { playlistToRemove = entry }
                        }
                    }
                    NavigationLink("Add Playlist…") { AddPlaylistView() }
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
                    Toggle("Reconnect automatically when a live channel drops", isOn: $autoReconnect)
                } footer: {
                    Text("Off by default. Many providers allow only one stream per subscription and may ban accounts that open a second one. With this on, Playa can reopen a stream while another device is already watching.")
                }

                Section {
                    Picker("Channel list over the picture", selection: $panelOpacity) {
                        ForEach([20, 30, 40, 50, 60, 70, 80, 90, 100], id: \.self) { percent in
                            Text(percent == 100 ? "Solid" : "\(100 - percent)% see-through").tag(percent)
                        }
                    }
                } footer: {
                    Text("Swipe down or press select while watching to open the channel list. This sets how much of the picture shows through it.")
                }

                Section {
                    Text("Playlists, favourites and resume positions sync with Playa on your other devices signed in to the same Apple Account. Playlist addresses, which include your provider login, are stored in iCloud with Apple's standard encryption.")
                        .font(.caption)
                } header: {
                    Text("iCloud sync")
                }
                .foregroundStyle(.secondary)

                PINSettings()

                Section("TV guide") {
                    switch epg.status {
                    case .loading: Text("Loading…")
                    case .loaded: Text("Loaded")
                    case .unavailable: Text("Not available for this playlist")
                    case .failed(let message): Text("Unavailable: \(message)")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Remove “\(playlistToRemove?.name ?? "")”?",
                isPresented: Binding(get: { playlistToRemove != nil }, set: { if !$0 { playlistToRemove = nil } })
            ) {
                Button("Remove", role: .destructive) {
                    if let id = playlistToRemove?.id { Task { await store.remove(id) } }
                }
            }
        }
    }
}

/// Choose which of the playlist's groups to show.
struct GroupSettings: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var kind = ChannelKind.live

    private var groups: [String] { store.playlist.groupsByKind[kind] ?? [] }

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
                Button("Show All") { store.setHidden(false, groups: groups, kind: kind) }
                Button("Hide All") { store.setHidden(true, groups: groups, kind: kind) }
            } footer: {
                Text("Hidden groups disappear from the browser and from search. Channels you put in Favourites or a list stay there. \(groups.filter { !isHidden($0) }.count) of \(groups.count) shown.")
            }
            Section("Groups") {
                ForEach(groups, id: \.self) { group in
                    Button {
                        store.setHidden(!isHidden(group), groups: [group], kind: kind)
                    } label: {
                        HStack {
                            Text(group)
                                .foregroundStyle(isHidden(group) ? .secondary : .primary)
                            Spacer()
                            if !isHidden(group) { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Groups")
    }
}

struct AddPlaylistView: View {
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""

    var body: some View {
        VStack(spacing: 30) {
            Text("Add Playlist")
                .font(.title2)
            Text("Enter the M3U address from your IPTV provider. Typing is easier with the keyboard on an iPhone, which appears as a notification when this field is selected.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("http://provider.example/get.php?…", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Name (optional)", text: $name)

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
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
        .frame(maxWidth: 1100)
        .padding(60)
        .onAppear { store.errorMessage = nil }
    }
}
