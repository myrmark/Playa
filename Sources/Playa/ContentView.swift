import AppKit
import PlayaCore
import SwiftUI
import UniformTypeIdentifiers

enum ChannelFilter: Hashable {
    case all
    case favourites
    case recent
    case list(UUID)
    case group(String)

    /// For remembering which one to open at launch.
    var storageValue: String {
        switch self {
        case .all: "all"
        case .favourites: "favourites"
        case .recent: "recent"
        case .list(let id): "list:\(id.uuidString)"
        case .group(let name): "group:\(name)"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "all": self = .all
        case "favourites": self = .favourites
        case "recent": self = .recent
        case let value where value.hasPrefix("list:"):
            guard let id = UUID(uuidString: String(value.dropFirst(5))) else { return nil }
            self = .list(id)
        case let value where value.hasPrefix("group:"):
            self = .group(String(value.dropFirst(6)))
        default:
            return nil
        }
    }
}

/// What the list-name prompt is for.
private enum ListPrompt: Identifiable {
    /// A new list, holding the given channels or shows from the start.
    case new(adding: [String])
    case rename(UUID)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let id): id.uuidString
        }
    }
}

struct ContentView: View {
    @StateObject private var store = PlaylistStore()
    @StateObject private var epg = EPGStore()
    @StateObject private var resume = ResumeStore()
    @StateObject private var following = FollowingStore()
    @EnvironmentObject private var playback: PlaybackCommands
    /// The channel before the current one, for "Back to Last Channel".
    @State private var lastChannel: Channel?
    /// Live channels whose past programmes the provider keeps, as the playlist says.
    @State private var catchUpCount = 0
    @State private var archiveMaxDays = 0
    @State private var showingFollowing = false
    @AppStorage(SettingsView.autoplayKey) private var autoplayOnLaunch = false
    /// The last channel is selected at launch but not played until the user asks: starting a
    /// stream unprompted could be a second one on a single-stream subscription.
    /// In full screen the picture gets the whole screen: no sidebar, no toolbar.
    @State private var isFullScreen = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var visibilityBeforeFullScreen = NavigationSplitViewVisibility.all
    @State private var holdsPlayback = false
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
    /// For channels a search found through the guide: the matching programme, by channel id.
    @State private var programmeMatches: [Int: String] = [:]
    @State private var visibleShows: [SeriesShow] = []
    /// The show whose episodes the Series section is showing, if any.
    @State private var openShow: SeriesShow?
    @State private var showingPlaylistSheet = false
    @State private var playlistToEdit: SavedPlaylist?
    @State private var showingGuide = false
    @State private var playlistToRemove: SavedPlaylist?
    @State private var listPrompt: ListPrompt?
    @State private var listName = ""
    @State private var listToDelete: ChannelList?
    @State private var showingGroupChooser = false
    /// The section and filter to open at launch, as "live|group:Sweden"; empty for none.
    @AppStorage("startFilter.mac") private var startValue = ""

    private var currentStartValue: String { "\(section.rawValue)|\(filter.storageValue)" }

    private var filterTitle: String {
        switch filter {
        case .all: section.allTitle
        case .favourites: "Favourites"
        case .recent: "Recently Watched"
        case .list: currentList?.name ?? "List"
        case .group(let name): name
        }
    }

    /// Opens what the user pinned, if it still exists in this playlist.
    private func openStartFilter() {
        let parts = startValue.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = ChannelKind(rawValue: parts[0]), store.playlist.countByKind[kind] != nil,
              let wanted = ChannelFilter(storageValue: parts[1])
        else { return }
        switch wanted {
        case .list(let id): guard store.lists.contains(where: { $0.id == id }) else { return }
        case .group(let name): guard store.visibleGroups(kind).contains(name) else { return }
        case .all, .favourites, .recent: break
        }
        section = kind
        // Changing the section resets a group filter, so the filter is set once that has happened.
        DispatchQueue.main.async { filter = wanted }
    }

    /// The list the sidebar is showing, if it is showing one.
    private var currentList: ChannelList? {
        guard case .list(let id) = filter else { return nil }
        return store.lists.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 720)
        } detail: {
            // The player lives in its own view so that playback state changes
            // don't re-render the (potentially huge) channel list.
            PlayerPane(
                channel: selectedChannel,
                resume: resume,
                isHeld: holdsPlayback,
                release: { holdsPlayback = false },
                hold: { holdsPlayback = true },
                playlistError: store.errorMessage,
                noteWatched: { channel in
                    guard !channel.isArchive else { return }
                    // An episode also brings its show to the front of the recent shows.
                    let show = store.playlist.shows.first { show in
                        channel.kind == .series && show.seasons.contains { $0.episodes.contains { $0.channelID == channel.id } }
                    }
                    store.noteWatched([channel.key] + (show.map { [$0.favouriteKey] } ?? []))
                },
                zap: zap,
                startOver: startOverRecording.map { recording in { selectedChannel = recording } },
                archiveDays: selectedChannel.flatMap { store.catchUp(for: $0) }?.days,
                watchFrom: { start, minutes in
                    guard let channel = selectedChannel, let catchUp = store.catchUp(for: channel),
                          let recording = channel.archived(from: start, minutes: minutes, catchUp: catchUp)
                    else { return }
                    selectedChannel = recording
                },
                // The guide has a search field of its own, where these keys must type.
                spaceTogglesPause: !isSearching && !showingGuide && !showingFollowing,
                programmes: epg.guide.nowAndNext(channelID: selectedChannel?.tvgID, at: now),
                isFavourite: selectedChannel.map { store.favourites.contains($0.key) } ?? false,
                toggleFavourite: { if let selectedChannel { store.toggleFavourite(selectedChannel) } },
                isFullScreen: isFullScreen
            )
                .navigationTitle(selectedChannel?.name ?? "Playa")
        }
        // Hiding the toolbar outright would also take the window buttons with it; instead it
        // slides down with the menu bar when the pointer reaches the top of the screen.
        .modifier(ToolbarOnHoverInFullScreen())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            visibilityBeforeFullScreen = columnVisibility
            columnVisibility = .detailOnly
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            columnVisibility = visibilityBeforeFullScreen
            isFullScreen = false
        }
        .overlay {
            if showingGuide {
                GuideView(
                    playlist: store.playlist,
                    guide: epg.guide,
                    favourites: store.favourites,
                    lists: store.lists,
                    recents: store.recents,
                    hiddenGroups: store.hiddenGroups,
                    now: now,
                    initialFilter: guideStartFilter,
                    playingChannel: selectedChannel,
                    catchUp: store.catchUp(for:),
                    archiveDays: archiveMaxDays,
                    onPlay: { channel in
                        selectedChannel = channel
                        showingGuide = false
                    },
                    onClose: { showingGuide = false }
                )
            }
        }
        .overlay {
            if showingFollowing {
                FollowingView(
                    following: following,
                    playlist: store.playlist,
                    guide: epg.guide,
                    guideVersion: epg.version,
                    favourites: store.favourites,
                    lists: store.lists,
                    hiddenGroups: store.hiddenGroups,
                    now: now,
                    onPlay: { channel in
                        holdsPlayback = false
                        selectedChannel = channel
                        showingFollowing = false
                    },
                    onClose: { showingFollowing = false }
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingGuide = false
                    showingFollowing.toggle()
                } label: {
                    Label("Following", systemImage: "binoculars")
                }
                .help("Broadcasts of the teams and shows you follow (⇧⌘F)")

                Button {
                    showingFollowing = false
                    showingGuide.toggle()
                } label: {
                    Label("TV Guide", systemImage: "calendar")
                }
                .help(epg.guide.isEmpty ? "No TV guide is available for this playlist" : "Show the TV guide (⌘G)")
                .disabled(epg.guide.isEmpty)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Reload playlist", systemImage: "arrow.clockwise")
                }
                .help("Download the playlist again")
                .disabled(store.active == nil || store.isLoading)

                // Which playlist is open, switching between them, and adding or removing one.
                playlistMenu
            }
        }
        .sheet(isPresented: $showingPlaylistSheet) {
            PlaylistSheet(store: store)
        }
        .sheet(item: $playlistToEdit) { entry in
            PlaylistSheet(store: store, editing: entry)
        }
        .sheet(isPresented: $showingGroupChooser) {
            GroupChooser(store: store, kind: section)
        }
        .onReceive(store.$hiddenGroups) { hidden in
            if case .group(let group) = filter, hidden.contains(PlaylistStore.hiddenKey(group: group, kind: section)) {
                filter = .all
            } else {
                updateVisibleChannels(in: store.playlist, favourites: store.favourites, hidden: hidden)
            }
        }
        .alert(
            { if case .rename = listPrompt { "Rename List" } else { "New List" } }(),
            isPresented: Binding(get: { listPrompt != nil }, set: { if !$0 { listPrompt = nil } }),
            presenting: listPrompt
        ) { prompt in
            TextField("Name", text: $listName)
            Button("Cancel", role: .cancel) {}
            Button({ if case .rename = prompt { "Rename" } else { "Create" } }()) {
                switch prompt {
                case .new(let keys):
                    let id = store.createList(named: listName, adding: keys)
                    // A list made from the menu button, rather than from a channel, is opened.
                    if keys.isEmpty { filter = .list(id) }
                case .rename(let id):
                    store.renameList(id, to: listName)
                }
            }
            .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog(
            "Delete the list “\(listToDelete?.name ?? "")”?",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = listToDelete?.id { store.deleteList(id) }
            }
        } message: {
            Text("The channels in it are not affected. The list is removed from your other devices too.")
        }
        .task {
            await store.loadOnLaunch()
            openStartFilter()
            if store.saved.isEmpty {
                showingPlaylistSheet = true
            } else if let last = store.lastChannelURL,
                      let channel = store.playlist.channels.first(where: { $0.url == last }) {
                holdsPlayback = !autoplayOnLaunch
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
            loadGuide(for: playlist)
        }
        // The provider's archive list arrives after the playlist; past programmes are then kept.
        .onChange(of: store.archive) { loadGuide(for: store.playlist) }
        // Another server to ask is a reason to ask for the guide again.
        .onChange(of: store.active?.alternativeServers) { loadGuide(for: store.playlist) }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(store.$favourites) { favourites in
            if filter == .favourites {
                updateVisibleChannels(in: store.playlist, favourites: favourites)
            }
        }
        .onReceive(store.$recents) { recents in
            if filter == .recent {
                updateVisibleChannels(in: store.playlist, favourites: store.favourites, recents: recents)
            }
        }
        .onReceive(store.$lists) { lists in
            guard case .list(let id) = filter else { return }
            if lists.contains(where: { $0.id == id }) {
                updateVisibleChannels(in: store.playlist, favourites: store.favourites, lists: lists)
            } else {
                filter = .all
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
        .onChange(of: selectedChannel) { old, channel in
            // Picking a different channel is the user asking to play.
            if let old, old.url != channel?.url {
                holdsPlayback = false
                lastChannel = old
            }
            // A recording from the archive isn't in the playlist, so it can't be reopened at launch.
            if let channel, !channel.isArchive { store.lastChannelURL = channel.url }
            playback.hasChannel = channel != nil
            playback.isLive = channel?.kind != .series && channel?.kind != .movie
            playback.lastChannelName = lastChannel?.name
        }
        .onChange(of: !isSearching && !showingGuide && !showingFollowing, initial: true) { _, free in
            playback.keysFree = free
        }
        .onChange(of: epg.status, initial: true) { playback.canRefreshGuide = epg.canRefresh }
        .onChange(of: epg.version, initial: true) {
            playback.hasGuide = !epg.guide.isEmpty
            // Keeps the reminders for followed broadcasts up to date with the guide.
            if Reminders.isEnabled, !epg.guide.isEmpty {
                following.search(guide: epg.guide, playlist: store.playlist, favourites: store.favourites, lists: store.lists, hiddenGroups: store.hiddenGroups)
            }
        }
        .onAppear {
            playback.zap = zap
            playback.backToLastChannel = {
                guard let lastChannel else { return }
                holdsPlayback = false
                selectedChannel = lastChannel
            }
            playback.toggleFavourite = { if let selectedChannel { store.toggleFavourite(selectedChannel) } }
            playback.showGuide = {
                guard !epg.guide.isEmpty else { return }
                showingFollowing = false
                showingGuide.toggle()
            }
            playback.refreshGuide = { epg.refresh() }
            playback.showFollowing = {
                showingGuide = false
                showingFollowing.toggle()
            }
        }
    }

    /// Loads the guide, keeping past programmes of the channels with an archive.
    private func loadGuide(for playlist: Playlist) {
        var days: [String: Int] = [:]
        var count = 0
        for channel in playlist.channels where channel.kind == .live {
            guard let catchUp = store.catchUp(for: channel) else { continue }
            count += 1
            if let id = channel.tvgID?.lowercased() { days[id] = max(days[id] ?? 0, catchUp.days) }
        }
        catchUpCount = count
        archiveMaxDays = days.values.max() ?? 0
        epg.load(for: store.active, playlist: playlist, archiveDays: days)
    }

    /// The programme on now, from the start, when the channel keeps an archive.
    private var startOverRecording: Channel? {
        guard let channel = selectedChannel, let catchUp = store.catchUp(for: channel),
              let programme = epg.guide.nowAndNext(channelID: channel.tvgID, at: now).now
        else { return nil }
        return channel.archived(programme, catchUp: catchUp)
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
        let hasLiveFavourite = store.playlist.channels.contains { $0.kind == .live && $0.tvgID != nil && store.favourites.contains($0.key) }
        return hasLiveFavourite ? .favourites : .all
    }

    /// Filters on a background thread: matching text against a provider-sized playlist
    /// takes long enough to make typing in the search field stutter.
    private func updateVisibleChannels(
        in playlist: Playlist, favourites: Set<String>, lists: [ChannelList]? = nil, hidden: Set<String>? = nil,
        recents: [String]? = nil, afterTyping: Bool = false
    ) {
        // Lists and Recently Watched have an order of their own; everything else follows the playlist.
        var ordered: [String]?
        if case .list(let id) = filter { ordered = (lists ?? store.lists).first { $0.id == id }?.keys }
        if filter == .recent { ordered = recents ?? store.recents }
        filterTask?.cancel()
        let section = section, filter = filter, searchText = searchText
        // Only groups of this section matter, by name.
        let prefix = PlaylistStore.hiddenKey(group: "", kind: section)
        let hiddenGroups = Set((hidden ?? store.hiddenGroups).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })

        filterTask = Task {
            if afterTyping {
                // Wait for a pause in typing instead of filtering on every keystroke.
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            // In Live TV a search also looks through the guide, so a programme can be found
            // without knowing which channel shows it.
            let guide = section == .live && searchText.count >= 3 ? epg.guide : Guide()
            let result = await Task.detached(priority: .userInitiated) { () -> (channels: [Channel], shows: [SeriesShow], labels: [Int: String]) in
                var items = Self.visibleItems(
                    in: playlist, section: section, filter: filter, searchText: searchText,
                    favourites: favourites, ordered: ordered, hiddenGroups: hiddenGroups
                )
                guard !guide.isEmpty else { return (items.channels, items.shows, [:]) }
                let now = Date()
                let members = Set(ordered ?? [])
                let alreadyListed = Set(items.channels.map(\.id))
                var labels: [Int: String] = [:]
                for hit in guide.channels(showing: searchText, in: playlist, from: now, hiddenGroups: hiddenGroups) {
                    switch filter {
                    case .all: break
                    case .favourites: guard favourites.contains(hit.channel.key) else { continue }
                    case .list, .recent: guard members.contains(hit.channel.key) else { continue }
                    case .group(let group): guard hit.channel.group == group else { continue }
                    }
                    labels[hit.channel.id] = hit.programme.searchLabel(at: now)
                    // Channels found by name come first; these follow, soonest programme first.
                    if !alreadyListed.contains(hit.channel.id) { items.channels.append(hit.channel) }
                }
                return (items.channels, items.shows, labels)
            }.value
            if Task.isCancelled { return }
            listGeneration += 1
            visibleChannels = result.channels
            visibleShows = result.shows
            programmeMatches = result.labels
        }
    }

    private nonisolated static func visibleItems(
        in playlist: Playlist, section: ChannelKind, filter: ChannelFilter, searchText: String, favourites: Set<String>,
        ordered: [String]?, hiddenGroups: Set<String>
    ) -> (channels: [Channel], shows: [SeriesShow]) {
        func matchesSearch(_ name: String) -> Bool {
            searchText.isEmpty || name.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let members = Set(ordered ?? [])
        // A list keeps the order its owner gave it, not the playlist's.
        let position = Dictionary((ordered ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        if section == .series {
            // Series are browsed by show; the episode list comes from the open show.
            let shows = playlist.shows.filter { show in
                switch filter {
                case .all: guard !hiddenGroups.contains(show.group) else { return false }
                case .favourites: guard favourites.contains(show.favouriteKey) else { return false }
                case .list, .recent: guard members.contains(show.favouriteKey) else { return false }
                case .group(let group): guard show.group == group else { return false }
                }
                return matchesSearch(show.name)
            }
            if ordered != nil {
                return ([], shows.sorted { (position[$0.favouriteKey] ?? 0) < (position[$1.favouriteKey] ?? 0) })
            }
            return ([], shows)
        }
        if filter == .all && searchText.isEmpty && playlist.countByKind.count <= 1 && hiddenGroups.isEmpty {
            return (playlist.channels, [])
        }
        let channels = playlist.channels.filter { channel in
            guard channel.kind == section else { return false }
            switch filter {
            case .all: guard !hiddenGroups.contains(channel.group) else { return false }
            case .favourites: guard favourites.contains(channel.key) else { return false }
            case .list, .recent: guard members.contains(channel.key) else { return false }
            case .group(let group): guard channel.group == group else { return false }
            }
            return matchesSearch(channel.name)
        }
        if ordered != nil {
            return (channels.sorted { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }, [])
        }
        return (channels, [])
    }

    /// The "Add to List" submenu for a channel, film, episode or show.
    private func listMenuItems(for key: String) -> [RowMenuItem] {
        var items = store.lists.map { list in
            RowMenuItem(title: list.name, isOn: list.contains(key), action: { store.toggle(key, inList: list.id) })
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(RowMenuItem(title: "New List…", action: { promptForNewList(adding: [key]) }))
        return items
    }

    private func promptForNewList(adding keys: [String]) {
        listName = ""
        listPrompt = .new(adding: keys)
    }

    /// The right-click menu for one row, or for several selected together.
    private func rowMenu(for channels: [Channel]) -> [RowMenuItem] {
        guard channels.count > 1 else { return channels.first.map(rowMenu(for:)) ?? [] }
        let keys = channels.map(\.key)
        var listItems = store.lists.map { list in
            RowMenuItem(title: list.name, action: { store.add(keys, toList: list.id) })
        }
        if !listItems.isEmpty { listItems.append(.separator) }
        listItems.append(RowMenuItem(title: "New List…", action: { promptForNewList(adding: keys) }))
        var items = [
            RowMenuItem(title: "Add \(keys.count) to Favourites", action: { store.addFavourites(keys) }),
            RowMenuItem(title: "Add \(keys.count) to List", children: listItems),
        ]
        if let list = currentList {
            items.append(.separator)
            items.append(RowMenuItem(title: "Remove \(keys.count) from “\(list.name)”", action: { store.remove(keys, fromList: list.id) }))
        }
        return items
    }

    private func rowMenu(for channel: Channel) -> [RowMenuItem] {
        var items = [
            RowMenuItem(
                title: store.favourites.contains(channel.key) ? "Remove from Favourites" : "Add to Favourites",
                action: { store.toggleFavourite(channel) }
            ),
            RowMenuItem(title: "Add to List", children: listMenuItems(for: channel.key)),
        ]
        // Rearranging only makes sense while the whole list is showing.
        guard let list = currentList, searchText.isEmpty, section != .series,
              let index = visibleChannels.firstIndex(of: channel)
        else { return items }
        func move(before other: Channel?) {
            store.move(channel.key, before: other?.key, inList: list.id)
        }
        items.append(.separator)
        if index > 0 {
            items.append(RowMenuItem(title: "Move to Top", action: { move(before: visibleChannels.first) }))
            items.append(RowMenuItem(title: "Move Up", action: { move(before: visibleChannels[index - 1]) }))
        }
        if index < visibleChannels.count - 1 {
            let after = index + 2 < visibleChannels.count ? visibleChannels[index + 2] : nil
            items.append(RowMenuItem(title: "Move Down", action: { move(before: after) }))
        }
        items.append(RowMenuItem(title: "Remove from “\(list.name)”", action: { store.toggle(channel.key, inList: list.id) }))
        return items
    }

    /// New, rename and delete for lists, next to the group picker.
    private var listMenu: some View {
        Menu {
            Button("New List…") { promptForNewList(adding: []) }
            if let list = currentList {
                Divider()
                Button("Rename “\(list.name)”…") {
                    listName = list.name
                    listPrompt = .rename(list.id)
                }
                Button("Delete “\(list.name)”…", role: .destructive) { listToDelete = list }
            }
            Divider()
            Toggle("Open “\(filterTitle)” at Launch", isOn: Binding(
                get: { startValue == currentStartValue },
                set: { startValue = $0 ? currentStartValue : "" }
            ))
            Button("Choose Groups…") { showingGroupChooser = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Lists and groups")
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
            if store.active != nil {
                Text(catchUpCount > 0 ? "Catch-up on \(catchUpCount) channels" : "No catch-up in this playlist")
            }
            if let active = store.active {
                Button("Edit “\(active.name)”…") { playlistToEdit = active }
                Button("Remove “\(active.name)”", role: .destructive) {
                    playlistToRemove = active
                }
            }
        } label: {
            Label(store.active?.name ?? "No playlist", systemImage: "list.bullet.rectangle")
                .labelStyle(.titleAndIcon)
        }
        .help("Switch playlist, or add or remove one")
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
            VStack(alignment: .leading, spacing: 2) {
                Text("TV guide unavailable: \(message)")
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button("Try Again") { epg.refresh() }
                    .buttonStyle(.link)
                    .help("Ask for the TV guide again. Playa also tries by itself every quarter of an hour.")
            }
            .font(.caption)
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

            HStack(spacing: 8) {
                Picker("Group", selection: $filter) {
                    // The total would be wrong once groups are hidden, so it is only shown when none are.
                    Text(store.visibleGroups(section).count == (store.playlist.groupsByKind[section] ?? []).count
                        ? "\(section.allTitle) (\(section == .series ? store.playlist.shows.count : store.playlist.countByKind[section] ?? 0))"
                        : section.allTitle).tag(ChannelFilter.all)
                    Label("Favourites", systemImage: "star.fill").tag(ChannelFilter.favourites)
                    Label("Recently Watched", systemImage: "clock").tag(ChannelFilter.recent)
                    ForEach(store.lists) { list in
                        Label(list.name, systemImage: "list.bullet").tag(ChannelFilter.list(list.id))
                    }
                    Divider()
                    ForEach(store.visibleGroups(section), id: \.self) { group in
                        Text(group).tag(ChannelFilter.group(group))
                    }
                }
                .labelsHidden()
                listMenu
            }
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
                        toggleFavourite: store.toggleFavourite,
                        lists: store.lists,
                        toggleShowInList: { key, id in store.toggle(key, inList: id) },
                        newList: { key in promptForNewList(adding: [key]) },
                        episodeMenu: rowMenu(for:)
                    )
                } else {
                    ChannelTable(
                        channels: visibleChannels,
                        generation: listGeneration,
                        favourites: store.favourites,
                        guideStamp: epg.version &* 1_000_000 &+ Int(now.timeIntervalSince1970 / 60) % 1_000_000 &+ resume.version,
                        selection: $selectedChannel,
                        toggleFavourite: store.toggleFavourite,
                        subtitle: { [guide = epg.guide, now, programmeMatches] channel in
                            if let match = programmeMatches[channel.id] { return match }
                            return channel.kind == .live
                                ? guide.nowAndNext(channelID: channel.tvgID, at: now).now?.title
                                : resume.label(for: channel)
                        },
                        menu: rowMenu(for:),
                        catchUpDays: { store.catchUp(for: $0)?.days },
                        onMove: currentList.flatMap { list in
                            searchText.isEmpty ? { channel, before in store.move(channel.key, before: before?.key, inList: list.id) } : nil
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
                } else if isListEmpty && filter == .recent && searchText.isEmpty {
                    ContentUnavailableView("Nothing watched yet", systemImage: "clock", description: Text("What you watch for more than a few seconds shows up here."))
                } else if isListEmpty, let list = currentList, searchText.isEmpty {
                    ContentUnavailableView("“\(list.name)” is empty here", systemImage: "list.bullet", description: Text(section == .series
                        ? "Right-click a show and choose Add to List."
                        : "Right-click a channel and choose Add to List."))
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

extension ChannelKind {
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
        case .live: "Search channels and programmes"
        case .movie: "Search films"
        case .series: "Search series"
        }
    }
}

private struct PlayerPane: View {
    let channel: Channel?
    let resume: ResumeStore
    /// While held, the selected channel is shown but no stream is opened.
    let isHeld: Bool
    let release: () -> Void
    /// Puts the player back to holding, as when the sleep timer has stopped it.
    let hold: () -> Void
    let playlistError: String?
    /// Called once a channel has been on for a little while, to record it as recently watched.
    let noteWatched: (Channel) -> Void
    let zap: (Int) -> Void
    /// Plays the current programme from its start, from the channel's archive; nil when there is none.
    let startOver: (() -> Void)?
    /// How far back the channel's archive reaches; nil when it has none.
    let archiveDays: Int?
    /// Plays the channel's archive from a time picked by hand, for so many minutes.
    let watchFrom: (Date, Int) -> Void
    /// Off while the search field has focus, so a space (and M, + and −) can be typed there.
    let spaceTogglesPause: Bool
    let programmes: (now: Programme?, next: Programme?)
    let isFavourite: Bool
    let toggleFavourite: () -> Void
    /// In full screen the controls float over the picture and fade away while the mouse rests.
    let isFullScreen: Bool

    @StateObject private var player = MPVPlayer()
    @EnvironmentObject private var playback: PlaybackCommands
    @State private var showsControls = true
    @State private var showsWatchFrom = false
    /// In a narrow window the controls keep to the essentials: the volume slider and the larger
    /// skips are left out (the keys and the menu still do both).
    @State private var isNarrow = false
    @State private var nowPlaying = NowPlaying()
    @State private var isOverControls = false
    @State private var hideTask: Task<Void, Never>?
    /// Slider value while the user is dragging the seek bar.
    @State private var scrubPosition: Double?
    /// Where along the timeline the pointer is, while it is over it.
    @State private var hoverX: CGFloat?
    /// What the player is showing, kept so its position can be saved when the selection moves on.
    @State private var playing: Channel?
    @State private var watchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            VideoView(player: player)

            if channel == nil {
                Text("Choose a channel")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else if isHeld, let channel {
                Button(action: release) {
                    Label("Play \(channel.name)", systemImage: "play.fill")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else if let error = player.errorMessage ?? playlistError {
                VStack(spacing: 10) {
                    Text(error)
                    if player.canRetry {
                        Button("Reconnect") { player.retry() }
                    }
                }
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
            if !isFullScreen { controls }
        }
        .overlay(alignment: .bottom) {
            if isFullScreen, showsControls || player.isPaused {
                controls
                    .onHover { isOverControls = $0 }
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if isFullScreen, case .active = phase { revealControls() }
        }
        .onChange(of: isFullScreen) { _, _ in revealControls() }
        // Keyed on the stream, so a playlist refresh that renumbers channels doesn't restart playback.
        .onChange(of: channel?.url, initial: true) { _, _ in startPlayback() }
        .onChange(of: isHeld) { _, _ in startPlayback() }
        .onAppear {
            playback.togglePause = { if isHeld { release() } else { player.togglePause() } }
            playback.toggleMute = { player.isMuted.toggle() }
            playback.changeVolume = { change in
                player.isMuted = false
                player.volume = min(max(player.volume + change, 0), 100)
            }
            playback.setSleepTimer = { player.setSleepTimer(minutes: $0) }
            playback.skip = { skip($0) }
            nowPlaying.togglePause = { player.togglePause() }
        }
        .onChange(of: NowPlayingState(
            title: isHeld ? nil : playing?.name, detail: playing?.kind == .live ? programmes.now?.title : nil,
            isPaused: player.isPaused, isLive: playing?.kind == .live,
            // A film's position is passed on again every quarter of a minute, and so after a jump.
            step: playing?.kind == .live || player.duration <= 0 ? -1 : Int(player.position) / 15
        ), initial: true) { _, state in
            nowPlaying.update(
                title: state.title, detail: state.detail, isPaused: state.isPaused, isLive: state.isLive,
                position: player.position, duration: player.duration
            )
        }
        .onChange(of: player.isPaused || isHeld, initial: true) { _, paused in playback.isPaused = paused }
        .onChange(of: player.isMuted, initial: true) { _, muted in playback.isMuted = muted }
        .onChange(of: player.sleepAt, initial: true) { _, date in playback.sleepAt = date }
        .onChange(of: skipAmounts?.small, initial: true) {
            playback.skipSmall = skipAmounts?.small ?? 0
            playback.skipBig = skipAmounts?.big ?? 0
        }
        // The sleep timer has closed the stream: offer to play again rather than reopen it.
        .onChange(of: player.sleptAt) {
            savePosition(isFinal: true)
            playing = nil
            hold()
        }
        .onChange(of: player.position) { _, position in
            if Int(position) % 10 == 0, position > 0 { savePosition(isFinal: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            savePosition(isFinal: true)
        }
    }

    /// Shows the full-screen controls, and hides them with the pointer once the mouse rests.
    private func revealControls() {
        if !showsControls { withAnimation(.easeOut(duration: 0.15)) { showsControls = true } }
        hideTask?.cancel()
        guard isFullScreen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isFullScreen, !isOverControls else { return }
            withAnimation { showsControls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func startPlayback() {
        guard !isHeld, let channel, channel.url != playing?.url else { return }
        savePosition(isFinal: true)
        playing = channel
        player.play(url: channel.url, startAt: resume.resumePosition(for: channel), isLive: channel.kind == .live, recording: channel.recording)
        // Zapping past a channel shouldn't count as watching it.
        watchTask?.cancel()
        watchTask = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, playing?.url == channel.url { noteWatched(channel) }
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
            // Under the pointer: the time a click there would jump to.
            .onContinuousHover { phase in
                if case .active(let point) = phase { hoverX = point.x } else { hoverX = nil }
            }
            .overlay {
                GeometryReader { geometry in
                    if let hoverX {
                        // The knob's centre stops half a knob short of either end.
                        let inset: CGFloat = 8
                        let fraction = min(max((hoverX - inset) / max(geometry.size.width - 2 * inset, 1), 0), 1)
                        Text(jumpLabel(fraction * player.duration))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .fixedSize()
                            .position(x: min(max(hoverX, 40), max(geometry.size.width - 40, 40)), y: -12)
                    }
                }
                .allowsHitTesting(false)
            }
            Text(Self.timestamp(player.duration))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// The two sizes of skip, in seconds; nil when there is nothing to skip in. A recording from
    /// the archive can only be entered on a whole minute, so its skips are whole minutes.
    private var skipAmounts: (small: Int, big: Int)? {
        guard let playing, playing.kind != .live, !isHeld, player.duration > 0 else { return nil }
        return playing.recording != nil ? (60, 300) : (15, 60)
    }

    private func skip(_ seconds: Int) {
        guard player.duration > 0 else { return }
        var target = player.position + Double(seconds)
        if playing?.recording != nil {
            // Counted in whole minutes from the one playing, so every press moves the same way.
            target = ((player.position / 60).rounded(.down) + Double(seconds / 60)) * 60
        }
        player.seek(to: min(max(target, 0), player.duration - 1))
    }

    private static func skipName(_ seconds: Int) -> String {
        let amount = abs(seconds)
        return amount < 60 ? "\(amount) Seconds" : amount == 60 ? "1 Minute" : "\(amount / 60) Minutes"
    }

    private func skipButton(_ seconds: Int, key: String) -> some View {
        let amount = abs(seconds)
        return Button {
            skip(seconds)
        } label: {
            Text((seconds < 0 ? "−" : "+") + (amount < 60 ? "\(amount)s" : "\(amount / 60)m"))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 30)
        }
        .help("Skip \(seconds < 0 ? "back" : "forward") \(Self.skipName(seconds).lowercased()) (\(key))")
    }

    /// What the timeline shows under the pointer. A recording is jumped in by the minute, and
    /// also gets the time of day it was broadcast.
    private func jumpLabel(_ seconds: Double) -> String {
        guard let recording = playing?.recording else { return Self.timestamp(seconds) }
        let minute = (seconds / 60).rounded(.down) * 60
        let broadcast = recording.start.addingTimeInterval(minute).formatted(date: .omitted, time: .shortened)
        return "\(Self.timestamp(minute))  ·  \(broadcast)"
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
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { isNarrow = $0 }
        // Changing the volume is asking to hear something.
        .onChange(of: player.volume) {
            if player.isMuted { player.isMuted = false }
        }
    }

    /// Invisible buttons that give the volume its keys. "=" is where "+" sits unshifted on
    /// keyboards that need Shift for "+".
    private var volumeKeys: some View {
        ZStack {
            // The Playback menu has + and −; "=" can't be a second shortcut for a menu item.
            ForEach(["="], id: \.self) { key in
                Button("") {
                    player.isMuted = false
                    player.volume = min(max(player.volume + (key == "-" ? -5 : 5), 0), 100)
                }
                .keyboardShortcut(spaceTogglesPause ? KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: []) : nil)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
                if isHeld { release() } else { player.togglePause() }
            } label: {
                Image(systemName: player.isPaused || isHeld ? "play.fill" : "pause.fill")
                    .frame(width: 20)
            }
            .help(player.isPaused || isHeld ? "Play (Space)" : "Pause (Space)")
            .disabled(channel == nil)

            if let channel, channel.kind != .live {
                Button {
                    player.seek(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("Start from the beginning")
                if let amounts = skipAmounts {
                    HStack(spacing: 4) {
                        if !isNarrow { skipButton(-amounts.big, key: "⇧←") }
                        skipButton(-amounts.small, key: "←")
                        skipButton(amounts.small, key: "→")
                        if !isNarrow { skipButton(amounts.big, key: "⇧→") }
                    }
                }
            } else {
                Button {
                    zap(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous channel (⌘↑)")
                .disabled(channel == nil)
                Button {
                    zap(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
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
                        // Hovering shows what the current programme is about, when the guide says.
                        .help(programmes.now?.description ?? "")
                }
            }
            if let startOver {
                Button(action: startOver) {
                    Image(systemName: "gobackward")
                }
                .help("Watch this programme from the start")
            }
            if let archiveDays, let channel {
                Button {
                    showsWatchFrom = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Watch from an earlier time, from the channel's archive")
                .popover(isPresented: $showsWatchFrom, arrowEdge: .top) {
                    WatchFromPicker(channelName: channel.name, days: archiveDays, play: watchFrom)
                }
            }
            Button(action: toggleFavourite) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .foregroundStyle(isFavourite ? Color.yellow : Color.secondary)
            }
            .help(isFavourite ? "Remove from Favourites" : "Add to Favourites")
            .disabled(channel == nil)
            Spacer()

            if let sleepAt = player.sleepAt {
                Menu {
                    Button("Turn Off Sleep Timer") { player.setSleepTimer(minutes: nil) }
                } label: {
                    Label(sleepAt.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The sleep timer stops playback at \(sleepAt.formatted(date: .omitted, time: .shortened))")
            }
            trackMenu
            Button {
                player.isMuted.toggle()
            } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(player.isMuted ? Color.primary : Color.secondary)
                    .frame(width: 22)
            }
            .help(player.isMuted ? "Unmute (M)" : "Mute (M)")
            if !isNarrow {
                Slider(value: $player.volume, in: 0...100)
                    .frame(width: 120)
                    .opacity(player.isMuted ? 0.4 : 1)
                    .help("Volume (+ and −)")
            }
            volumeKeys
        }
        .buttonStyle(.borderless)
    }
}

/// What the system is told about playback; a change in any of it is passed on.
private struct NowPlayingState: Equatable {
    var title: String?
    var detail: String?
    var isPaused: Bool
    var isLive: Bool
    var step: Int
}

private struct PlaylistSheet: View {
    @ObservedObject var store: PlaylistStore
    /// The playlist being changed, or nil when adding one.
    var editing: SavedPlaylist?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @State private var serversText = ""

    private var isFile: Bool { urlText.trimmingCharacters(in: .whitespaces).hasPrefix("file:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing == nil ? "Add Playlist" : "Edit Playlist")
                .font(.headline)
            Text(editing == nil
                 ? "Paste the M3U URL from your IPTV provider, or choose a playlist file on this Mac. Your other playlists are kept."
                 : "Change the name, or point the playlist at a new address or file. A new address is downloaded before it replaces the old one; favourites and lists stay with the channels that are still there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("http://provider.example/get.php?…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                Button("Choose File…", action: chooseFile)
            }
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
            if !isFile {
                TextField("Alternative servers (optional), such as http://other.example", text: $serversText)
                    .textFieldStyle(.roundedBorder)
                Text("Other servers your provider gives for the same account, separated by commas. Playa asks them in turn, with the same login, when the address above has no TV guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                Button(editing == nil ? "Add" : "Save") {
                    Task {
                        let servers = isFile ? [] : AlternativeServers.servers(from: serversText, besides: urlText)
                        let isDone = if let editing {
                            await store.edit(editing.id, name: name, url: urlText, alternativeServers: servers)
                        } else {
                            await store.add(name: name, url: urlText, alternativeServers: servers)
                        }
                        if isDone { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || store.isLoading)
            }
        }
        .frame(width: 520)
        .padding(20)
        .onAppear {
            store.errorMessage = nil
            if let editing {
                name = editing.name
                urlText = editing.url
                serversText = (editing.alternativeServers ?? []).joined(separator: ", ")
            }
        }
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

private struct ToolbarOnHoverInFullScreen: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}
