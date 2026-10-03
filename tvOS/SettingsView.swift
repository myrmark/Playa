import PlayaCore
import SwiftUI

/// The top level is a short menu of topics, each opening its own page, so no page is crowded.
struct SettingsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var player: MPVPlayer
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PlaylistSettings() } label: {
                        row("Playlists", systemImage: "list.bullet.rectangle", value: store.active?.name ?? "None")
                    }
                    NavigationLink { PlaybackSettings() } label: {
                        row("Playback", systemImage: "play.rectangle", value: "Picture: \(player.quality.title)")
                    }
                    NavigationLink {
                        List { PINSettings() }
                            .navigationTitle("PIN Lock")
                    } label: {
                        row("PIN Lock", systemImage: "lock", value: lock.isEnabled ? "On" : "Off")
                    }
                }
                Section {
                    row("TV Guide", systemImage: "calendar", value: guideStatus)
                    NavigationLink { SyncInfo() } label: {
                        row("iCloud Sync", systemImage: "icloud", value: nil)
                    }
                }
            }
            .navigationTitle("Settings")
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

    private func row(_ title: String, systemImage: String, value: String?) -> some View {
        HStack(spacing: 28) {
            Image(systemName: systemImage)
                .frame(width: 50)
            Text(title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The saved playlists, adding and reloading, and which groups are shown.
private struct PlaylistSettings: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var playlistToRemove: SavedPlaylist?

    var body: some View {
        List {
            Section {
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
            } header: {
                Text("Playlists")
            } footer: {
                Text("Select a playlist to open it. Hold select on one to remove it.")
            }

            Section {
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
            } header: {
                Text(store.active.map { "“\($0.name)”" } ?? "")
            }
        }
        .navigationTitle("Playlists")
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

private struct PlaybackSettings: View {
    @EnvironmentObject private var player: MPVPlayer
    @AppStorage(MPVPlayer.autoReconnectKey) private var autoReconnect = false
    @AppStorage(PlayerScreen.matchRateKey) private var matchesRate = false
    @AppStorage(PlayerScreen.panelOpacityKey) private var panelOpacity = PlayerScreen.defaultPanelOpacity

    var body: some View {
        List {
            Section {
                Picker("Picture", selection: $player.quality) {
                    ForEach(MPVPlayer.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Best is the sharpest. If a channel stutters with frames dropped while the stream itself keeps up, Balanced or Fast ask less of the Apple TV. Can also be changed while watching: swipe up.")
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
                Toggle("Match the screen's refresh rate", isOn: $matchesRate)
            } footer: {
                Text("Shows 50 fps channels at 50 Hz, which makes movement smoother. It also needs Match Frame Rate turned on in the Apple TV's own Video and Audio settings. Nothing happens if the screen already runs at the channel's rate. Otherwise it goes black for a moment when it switches, and on some TVs colours look different afterwards.")
            }

            Section {
                Toggle("Reconnect when a live channel drops", isOn: $autoReconnect)
            } footer: {
                Text("Off by default. Many providers allow only one stream per subscription and may ban accounts that open a second one. With this on, Playa can reopen a stream while another device is already watching.")
            }
        }
        .navigationTitle("Playback")
    }
}

private struct SyncInfo: View {
    var body: some View {
        Text("Playlists, favourites, lists and resume positions sync with Playa on your other devices signed in to the same Apple Account.\n\nPlaylist addresses, which include your provider login, are stored in iCloud with Apple's standard encryption. Your PIN is not synced.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: 1100)
            .padding(60)
            .navigationTitle("iCloud Sync")
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
