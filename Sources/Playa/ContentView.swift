import AppKit
import PlayaCore
import SwiftUI
import UniformTypeIdentifiers

enum ChannelFilter: Hashable {
    case all
    case favourites
    case group(String)
}

struct ContentView: View {
    @StateObject private var store = PlaylistStore()
    @StateObject private var epg = EPGStore()
    @StateObject private var resume = ResumeStore()
    /// Advances once a minute so now/next labels follow the clock.
    @State private var now = Date()

    @State private var section = ChannelKind.live
    @State private var filter = ChannelFilter.all
    @State private var selectedChannel: Channel?
    @State private var searchText = ""
    @FocusState private var isSearching: Bool
    @State private var visibleChannels: [Channel] = []
    @State private var listGeneration = 0
    @State private var filterTask: Task<Void, Never>?
    @State private var visibleShows: [SeriesShow] = []
    /// The show whose episodes the Series section is showing, if any.
    @State private var openShow: SeriesShow?
    @State private var showingPlaylistSheet = false
    @State private var showingGuide = false
    @State private var playlistToRemove: SavedPlaylist?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            // The player lives in its own view so that playback state changes
            // don't re-render the (potentially huge) channel list.
            PlayerPane(
                channel: selectedChannel,
                resume: resume,
                playlistError: store.errorMessage,
                zap: zap,
                spaceTogglesPause: !isSearching,
                programmes: epg.guide.nowAndNext(channelID: selectedChannel?.tvgID, at: now),
                isFavourite: selectedChannel.map { store.favourites.contains($0.url) } ?? false,
                toggleFavourite: { if let selectedChannel { store.toggleFavourite(selectedChannel) } }
            )
                .navigationTitle(selectedChannel?.name ?? "Playa")
        }
        .overlay {
            if showingGuide {
                GuideView(
                    playlist: store.playlist,
                    guide: epg.guide,
                    favourites: store.favourites,
                    now: now,
                    initialFilter: guideStartFilter,
                    playingChannel: selectedChannel,
                    onPlay: { channel in
                        selectedChannel = channel
                        showingGuide = false
                    },
                    onClose: { showingGuide = false }
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingGuide.toggle()
                } label: {
                    Label("TV Guide", systemImage: "calendar")
                }
                .keyboardShortcut("g", modifiers: .command)
                .help(epg.guide.isEmpty ? "No TV guide is available for this playlist" : "Show the TV guide (⌘G)")
                .disabled(epg.guide.isEmpty)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Reload playlist", systemImage: "arrow.clockwise")
                }
                .disabled(store.active == nil || store.isLoading)

                Button {
                    showingPlaylistSheet = true
                } label: {
                    Label("Add playlist…", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            PlaylistSheet(store: store)
        }
        .task {
            await store.loadOnLaunch()
            if store.saved.isEmpty {
                showingPlaylistSheet = true
            } else if let last = store.lastChannelURL,
                      let channel = store.playlist.channels.first(where: { $0.url == last }) {
                selectedChannel = channel
            }
        }
        .onReceive(store.$playlist) { playlist in
            // A refreshed playlist renumbers its channels; keep the selection on the same stream.
            if let current = selectedChannel,
               let match = playlist.channels.first(where: { $0.url == current.url }), match != current {
                selectedChannel = match
            }
            openShow = openShow.flatMap { old in playlist.shows.first { $0.name == old.name && $0.group == old.group } }
            if playlist.countByKind[section] == nil {
                section = ChannelKind.allCases.first { playlist.countByKind[$0] != nil } ?? .live
            }
            if case .group(let group) = filter, !(playlist.groupsByKind[section] ?? []).contains(group) {
                filter = .all
            }
            updateVisibleChannels(in: playlist, favourites: store.favourites)
            epg.load(for: store.active, playlist: playlist)
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(store.$favourites) { favourites in
            if filter == .favourites {
                updateVisibleChannels(in: store.playlist, favourites: favourites)
            }
        }
        .onChange(of: section) {
            // Group names differ between live TV, films and series.
            if case .group = filter { filter = .all }
            openShow = nil
            updateVisibleChannels(in: store.playlist, favourites: store.favourites)
        }
        .onChange(of: filter) {
            openShow = nil
            updateVisibleChannels(in: store.playlist, favourites: store.favourites)
        }
        .onChange(of: searchText) {
            openShow = nil
            updateVisibleChannels(in: store.playlist, favourites: store.favourites, afterTyping: !searchText.isEmpty)
        }
        .onChange(of: selectedChannel) { _, channel in
            if let channel { store.lastChannelURL = channel.url }
        }
    }

    /// Moves to the channel above (-1) or below (+1) the current one in the sidebar list.
    private func zap(_ offset: Int) {
        guard let current = selectedChannel, let index = visibleChannels.firstIndex(of: current),
              visibleChannels.indices.contains(index + offset)
        else { return }
        selectedChannel = visibleChannels[index + offset]
    }

    /// The guide opens on what the sidebar is showing, or on favourites when it shows everything.
    private var guideStartFilter: ChannelFilter {
        if section == .live, filter != .all { return filter }
        let hasLiveFavourite = store.playlist.channels.contains { $0.kind == .live && $0.tvgID != nil && store.favourites.contains($0.url) }
        return hasLiveFavourite ? .favourites : .all
    }

    /// Filters on a background thread: matching text against a provider-sized playlist
    /// takes long enough to make typing in the search field stutter.
    private func updateVisibleChannels(in playlist: Playlist, favourites: Set<String>, afterTyping: Bool = false) {
        filterTask?.cancel()
        let section = section, filter = filter, searchText = searchText
        filterTask = Task {
            if afterTyping {
                // Wait for a pause in typing instead of filtering on every keystroke.
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Self.visibleItems(in: playlist, section: section, filter: filter, searchText: searchText, favourites: favourites)
            }.value
            if Task.isCancelled { return }
            listGeneration += 1
            visibleChannels = result.channels
            visibleShows = result.shows
        }
    }

    private nonisolated static func visibleItems(
        in playlist: Playlist, section: ChannelKind, filter: ChannelFilter, searchText: String, favourites: Set<String>
    ) -> (channels: [Channel], shows: [SeriesShow]) {
        func matchesSearch(_ name: String) -> Bool {
            searchText.isEmpty || name.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if section == .series {
            // Series are browsed by show; the episode list comes from the open show.
            let shows = playlist.shows.filter { show in
                switch filter {
                case .all: break
                case .favourites: guard favourites.contains(show.favouriteKey) else { return false }
                case .group(let group): guard show.group == group else { return false }
                }
                return matchesSearch(show.name)
            }
            return ([], shows)
        }
        if filter == .all && searchText.isEmpty && playlist.countByKind.count <= 1 {
            return (playlist.channels, [])
        }
        let channels = playlist.channels.filter { channel in
            guard channel.kind == section else { return false }
            switch filter {
            case .all: break
            case .favourites: guard favourites.contains(channel.url) else { return false }
            case .group(let group): guard channel.group == group else { return false }
            }
            return matchesSearch(channel.name)
        }
        return (channels, [])
    }

    private var playlistMenu: some View {
        Menu {
            ForEach(store.saved) { entry in
                Toggle(entry.name, isOn: Binding(
                    get: { entry.id == store.activeID },
                    set: { _ in Task { await store.select(entry.id) } }
                ))
            }
            Divider()
            Button("Add Playlist…") { showingPlaylistSheet = true }
            if let active = store.active {
                Button("Remove “\(active.name)”", role: .destructive) {
                    playlistToRemove = active
                }
            }
        } label: {
            Label(store.active?.name ?? "No playlist", systemImage: "list.bullet.rectangle")
        }
        .confirmationDialog(
            "Remove “\(playlistToRemove?.name ?? "")”?",
            isPresented: Binding(get: { playlistToRemove != nil }, set: { if !$0 { playlistToRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let id = playlistToRemove?.id { Task { await store.remove(id) } }
            }
        } message: {
            Text("The playlist is removed from Playa. The original file or address is not affected.")
        }
    }

    @ViewBuilder
    private var guideStatus: some View {
        switch epg.status {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading TV guide…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(6)
        case .failed(let message):
            Text("TV guide unavailable: \(message)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(6)
        case .unavailable, .loaded:
            EmptyView()
        }
    }

    // A plain field rather than `.searchable`, which only shows itself above a SwiftUI List.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(section.searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearching)
                .onExitCommand {
                    searchText = ""
                    isSearching = false
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var isListEmpty: Bool {
        section == .series ? visibleShows.isEmpty : visibleChannels.isEmpty
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            playlistMenu
                .padding(.horizontal, 10)
                .padding(.top, 8)

            // Only shown when the playlist mixes live TV with on-demand content.
            if store.playlist.countByKind.count > 1 {
                Picker("Section", selection: $section) {
                    ForEach(ChannelKind.allCases.filter { store.playlist.countByKind[$0] != nil }, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            Picker("Group", selection: $filter) {
                Text("\(section.allTitle) (\(section == .series ? store.playlist.shows.count : store.playlist.countByKind[section] ?? 0))").tag(ChannelFilter.all)
                Label("Favourites", systemImage: "star.fill").tag(ChannelFilter.favourites)
                Divider()
                ForEach(store.playlist.groupsByKind[section] ?? [], id: \.self) { group in
                    Text(group).tag(ChannelFilter.group(group))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            searchField

            Group {
                if section == .series {
                    SeriesSidebar(
                        shows: visibleShows,
                        generation: listGeneration,
                        playlist: store.playlist,
                        resume: resume,
                        favourites: store.favourites,
                        openShow: $openShow,
                        selection: $selectedChannel,
                        toggleFavouriteKey: store.toggleFavourite(key:),
                        toggleFavourite: store.toggleFavourite
                    )
                } else {
                    ChannelTable(
                        channels: visibleChannels,
                        generation: listGeneration,
                        favourites: store.favourites,
                        guideStamp: epg.version &* 1_000_000 &+ Int(now.timeIntervalSince1970 / 60) % 1_000_000 &+ resume.version,
                        selection: $selectedChannel,
                        toggleFavourite: store.toggleFavourite,
                        subtitle: { [guide = epg.guide, now] channel in
                            channel.kind == .live
                                ? guide.nowAndNext(channelID: channel.tvgID, at: now).now?.title
                                : resume.label(for: channel)
                        }
                    )
                }
            }
            .overlay {
                if store.isLoading && store.playlist.channels.isEmpty {
                    ProgressView("Loading playlist…\n\(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                        .multilineTextAlignment(.center)
                } else if store.playlist.channels.isEmpty {
                    ContentUnavailableView("No playlist", systemImage: "tv", description: Text("Add an M3U URL or file to get started."))
                } else if isListEmpty && filter == .favourites && searchText.isEmpty {
                    ContentUnavailableView("No favourites yet", systemImage: "star", description: Text(section == .series
                        ? "Right-click a show to add it."
                        : "Right-click a channel, or press ⌘D while watching, to add it."))
                } else if isListEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if store.isLoading && !store.playlist.channels.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Updating playlist… \(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                }
                guideStatus
            }
        }
    }
}

private extension ChannelKind {
    var title: String {
        switch self {
        case .live: "Live TV"
        case .movie: "Films"
        case .series: "Series"
        }
    }

    var allTitle: String {
        switch self {
        case .live: "All channels"
        case .movie: "All films"
        case .series: "All shows"
        }
    }

    var searchPrompt: String {
        switch self {
        case .live: "Search channels"
        case .movie: "Search films"
        case .series: "Search series"
        }
    }
}

private struct PlayerPane: View {
    let channel: Channel?
    let resume: ResumeStore
    let playlistError: String?
    let zap: (Int) -> Void
    /// Off while the search field has focus, so a space can be typed there.
    let spaceTogglesPause: Bool
    let programmes: (now: Programme?, next: Programme?)
    let isFavourite: Bool
    let toggleFavourite: () -> Void

    @StateObject private var player = MPVPlayer()
    /// Slider value while the user is dragging the seek bar.
    @State private var scrubPosition: Double?
    /// What the player is showing, kept so its position can be saved when the selection moves on.
    @State private var playing: Channel?

    var body: some View {
        ZStack {
            Color.black
            VideoView(player: player)

            if channel == nil {
                Text("Choose a channel")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if let error = player.errorMessage ?? playlistError {
                Text(error)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            } else if player.isReconnecting {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Reconnecting…")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if player.isBuffering {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            controls
        }
        // Keyed on the stream, so a playlist refresh that renumbers channels doesn't restart playback.
        .onChange(of: channel?.url, initial: true) { _, _ in
            savePosition(isFinal: true)
            playing = channel
            if let channel {
                player.play(url: channel.url, startAt: resume.resumePosition(for: channel), isLive: channel.kind == .live)
            }
        }
        .onChange(of: player.position) { _, position in
            if Int(position) % 10 == 0, position > 0 { savePosition(isFinal: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            savePosition(isFinal: true)
        }
    }

    private func savePosition(isFinal: Bool) {
        // No length yet means the file hasn't loaded, so the position isn't meaningful.
        guard let playing, player.duration > 0 else { return }
        resume.record(playing, position: player.position, duration: player.duration, isFinal: isFinal)
    }

    private var programmeLine: String? {
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        var parts: [String] = []
        if let now = programmes.now {
            parts.append("Now: \(now.title) (\(time(now.start))–\(time(now.stop)))")
        }
        if let next = programmes.next {
            parts.append("Next: \(next.title) (\(time(next.start)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var seekBar: some View {
        HStack(spacing: 8) {
            Text(Self.timestamp(scrubPosition ?? player.position))
            Slider(
                value: Binding(get: { scrubPosition ?? player.position }, set: { scrubPosition = $0 }),
                in: 0...player.duration
            ) { isEditing in
                if !isEditing, let target = scrubPosition {
                    player.seek(to: target)
                    scrubPosition = nil
                }
            }
            .controlSize(.small)
            Text(Self.timestamp(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static func timestamp(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .hourMinuteSecond))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            // Films and episodes have a length to seek within; live channels don't.
            if let channel, channel.kind != .live, player.duration > 0 {
                seekBar
            }
            controlRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Audio and subtitle choices, shown only when the stream offers any.
    @ViewBuilder
    private var trackMenu: some View {
        let audio = player.tracks.filter { $0.kind == .audio }
        let subtitles = player.tracks.filter { $0.kind == .subtitle }
        if audio.count > 1 || !subtitles.isEmpty {
            Menu {
                if audio.count > 1 {
                    Section("Audio") {
                        ForEach(audio) { track in
                            Toggle(track.label, isOn: Binding(get: { track.isSelected }, set: { _ in player.selectAudio(track) }))
                        }
                    }
                }
                if !subtitles.isEmpty {
                    Section("Subtitles") {
                        Toggle("Off", isOn: Binding(
                            get: { !subtitles.contains(where: \.isSelected) },
                            set: { _ in player.selectSubtitle(nil) }
                        ))
                        ForEach(subtitles) { track in
                            Toggle(track.label, isOn: Binding(get: { track.isSelected }, set: { _ in player.selectSubtitle(track) }))
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio and subtitles")
        }
    }

    private var controlRow: some View {
        HStack(spacing: 14) {
            Button {
                player.togglePause()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 20)
            }
            .keyboardShortcut(spaceTogglesPause ? KeyboardShortcut(.space, modifiers: []) : nil)
            .disabled(channel == nil)

            if let channel, channel.kind != .live {
                Button {
                    player.seek(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Start from the beginning")
            } else {
                Button {
                    zap(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .help("Previous channel (⌘↑)")
                .disabled(channel == nil)
                Button {
                    zap(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .help("Next channel (⌘↓)")
                .disabled(channel == nil)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(channel?.name ?? "")
                    .lineLimit(1)
                if let line = programmeLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button(action: toggleFavourite) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .foregroundStyle(isFavourite ? Color.yellow : Color.secondary)
            }
            .keyboardShortcut("d", modifiers: .command)
            .help(isFavourite ? "Remove from Favourites" : "Add to Favourites")
            .disabled(channel == nil)
            Spacer()

            trackMenu
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...100)
                .frame(width: 120)
        }
        .buttonStyle(.borderless)
    }
}

private struct PlaylistSheet: View {
    @ObservedObject var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Playlist")
                .font(.headline)
            Text("Paste the M3U URL from your IPTV provider, or choose a playlist file on this Mac. Your other playlists are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("http://provider.example/get.php?…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                Button("Choose File…", action: chooseFile)
            }
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Downloading… \(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        if await store.add(name: name, url: urlText) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || store.isLoading)
            }
        }
        .frame(width: 520)
        .padding(20)
        .onAppear { store.errorMessage = nil }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            urlText = url.absoluteString
        }
    }
}
