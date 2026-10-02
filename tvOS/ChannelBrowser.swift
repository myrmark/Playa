import PlayaCore
import SwiftUI

enum ChannelFilter: Hashable {
    case favourites
    case list(UUID)
    case group(String)

    /// For remembering which one to open at launch.
    var storageValue: String {
        switch self {
        case .favourites: "favourites"
        case .list(let id): "list:\(id.uuidString)"
        case .group(let name): "group:\(name)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "favourites" {
            self = .favourites
        } else if storageValue.hasPrefix("list:"), let id = UUID(uuidString: String(storageValue.dropFirst(5))) {
            self = .list(id)
        } else if storageValue.hasPrefix("group:") {
            self = .group(String(storageValue.dropFirst(6)))
        } else {
            return nil
        }
    }
}

/// Where focus is in a two-pane browser: on an entry in the left column, or on an item on the right.
enum BrowserFocus: Hashable {
    case filter(ChannelFilter)
    case item(Int)
}

/// Requests for the list-name sheet, raised from menus anywhere in the app.
@MainActor
final class ListEditor: ObservableObject {
    enum Request: Identifiable {
        /// A new list, optionally holding a first channel or show.
        case new(adding: String?)
        case rename(ChannelList)

        var id: String {
            switch self {
            case .new(let key): "new-\(key ?? "")"
            case .rename(let list): list.id.uuidString
            }
        }
    }

    @Published var request: Request?
}

struct ListNameSheet: View {
    let request: ListEditor.Request
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var isRename: Bool {
        if case .rename = request { true } else { false }
    }

    var body: some View {
        VStack(spacing: 30) {
            Text(isRename ? "Rename List" : "New List")
                .font(.title2)
            TextField("Name", text: $name)
            Button(isRename ? "Rename" : "Create") {
                switch request {
                case .new(let key): store.createList(named: name, adding: key.map { [$0] } ?? [])
                case .rename(let list): store.renameList(list.id, to: name)
                }
                dismiss()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: 900)
        .padding(60)
        .onAppear {
            if case .rename(let list) = request { name = list.name }
        }
    }
}

/// Menu entries for putting a channel, film, episode or show in Favourites or a list.
struct MembershipMenu: View {
    let key: String
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var listEditor: ListEditor

    var body: some View {
        Button(store.favourites.contains(key) ? "Remove from Favourites" : "Add to Favourites") {
            store.toggleFavourite(key: key)
        }
        ForEach(store.lists) { list in
            Button(list.contains(key) ? "Remove from “\(list.name)”" : "Add to “\(list.name)”") {
                store.toggle(key, inList: list.id)
            }
        }
        Button("New List…") { listEditor.request = .new(adding: key) }
    }
}

/// Two panes side by side: Favourites, lists and groups on the left, and whatever the chosen
/// one holds on the right. Moving right goes into it; the back button returns to the left.
struct TwoPaneBrowser<Pane: View>: View {
    let kind: ChannelKind
    /// The right-hand pane for a filter. It gets the focus binding so its rows can take part,
    /// and a flag that asks it to take focus once its first item is ready.
    @ViewBuilder let pane: (ChannelFilter, FocusState<BrowserFocus?>.Binding, Binding<Bool>) -> Pane

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var listEditor: ListEditor
    @AppStorage private var startValue: String
    @State private var shown: ChannelFilter?
    @State private var wantsFocusInPane = false
    @State private var listToDelete: ChannelList?
    @FocusState private var focus: BrowserFocus?

    init(kind: ChannelKind, @ViewBuilder pane: @escaping (ChannelFilter, FocusState<BrowserFocus?>.Binding, Binding<Bool>) -> Pane) {
        self.kind = kind
        self.pane = pane
        _startValue = AppStorage(wrappedValue: "", "startFilter.\(kind.rawValue)")
    }

    private var groups: [String] { store.playlist.groupsByKind[kind] ?? [] }

    private var focusedFilter: ChannelFilter? {
        if case .filter(let filter) = focus { filter } else { nil }
    }

    /// The filter chosen to open at launch, if it still exists.
    private var startFilter: ChannelFilter? {
        guard let filter = ChannelFilter(storageValue: startValue) else { return nil }
        switch filter {
        case .favourites: return filter
        case .list(let id): return store.lists.contains { $0.id == id } ? filter : nil
        case .group(let name): return groups.contains(name) ? filter : nil
        }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                PlaylistLoadingView()
            } else {
                HStack(alignment: .top, spacing: 0) {
                    sidebar
                        .frame(width: 560)
                        .focusSection()
                    Group {
                        if let shown {
                            pane(shown, $focus, $wantsFocusInPane)
                                // A fresh pane per filter, so nothing of the previous one lingers.
                                .id(shown)
                        } else {
                            Text("Choose a list or group on the left.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .focusSection()
                    .onExitCommand {
                        // Back from the right pane returns to the left column instead of leaving the tab.
                        if let shown { focus = .filter(shown) }
                    }
                }
            }
        }
        .onAppear(perform: openStartFilter)
        .onChange(of: groups) { openStartFilter() }
        // The right pane follows the left column's focus after a short pause, so scrolling
        // down the column doesn't load every group on the way.
        .task(id: focusedFilter) {
            // While the pane opened at launch is still waiting to take focus, the left column's
            // automatic first focus must not replace it.
            guard let focusedFilter, focusedFilter != shown, !wantsFocusInPane else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled, !wantsFocusInPane { shown = focusedFilter }
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
    }

    private func openStartFilter() {
        guard shown == nil, !groups.isEmpty else { return }
        if let startFilter {
            shown = startFilter
            wantsFocusInPane = true
        } else {
            // Nothing chosen to open at launch: show favourites when there are any, else the first group.
            shown = store.favourites.isEmpty ? groups.first.map(ChannelFilter.group) : .favourites
        }
    }

    private var sidebar: some View {
        List {
            filterRow(.favourites, title: "Favourites", systemImage: "star.fill")
            ForEach(store.lists) { list in
                filterRow(.list(list.id), title: list.name, systemImage: "list.bullet", list: list)
            }
            Button {
                listEditor.request = .new(adding: nil)
            } label: {
                Label("New List…", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            Section("Groups") {
                ForEach(groups, id: \.self) { group in
                    filterRow(.group(group), title: group, systemImage: nil)
                }
            }
        }
    }

    private func filterRow(_ filter: ChannelFilter, title: String, systemImage: String?, list: ChannelList? = nil) -> some View {
        Button {
            shown = filter
            wantsFocusInPane = true
        } label: {
            HStack(spacing: 14) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if startValue == filter.storageValue {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                }
                if shown == filter {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
            }
        }
        .focused($focus, equals: .filter(filter))
        .contextMenu {
            if startValue == filter.storageValue {
                Button("Don't Open at Launch") { startValue = "" }
            } else {
                Button("Open at Launch") { startValue = filter.storageValue }
            }
            if let list {
                Button("Rename…") { listEditor.request = .rename(list) }
                Button("Delete List", role: .destructive) { listToDelete = list }
            }
        }
    }
}

/// Live TV or Films.
struct ChannelBrowser: View {
    let kind: ChannelKind

    var body: some View {
        TwoPaneBrowser(kind: kind) { filter, focus, wantsFocus in
            ChannelPane(kind: kind, filter: filter, focus: focus, wantsFocus: wantsFocus)
        }
    }
}

struct ChannelPane: View {
    let kind: ChannelKind
    let filter: ChannelFilter
    let focus: FocusState<BrowserFocus?>.Binding
    @Binding var wantsFocus: Bool

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @State private var channels: [Channel]?
    @State private var session: PlayerSession?
    /// Whether Live TV shows each channel's schedule as a timeline instead of a plain list.
    @AppStorage("liveShowsGuide") private var showsGuide = false
    @State private var windowStart = ChannelPane.currentWindowStart(for: Date())

    private static let windowLength: TimeInterval = 2 * 3600
    private static let step: TimeInterval = 3600

    /// The half hour that `date` falls in.
    private static func currentWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    private var canShowGuide: Bool { kind == .live && !epg.guide.isEmpty }
    private var isGuide: Bool { canShowGuide && showsGuide }

    /// Everything the channel list depends on, so it reloads when any of it changes.
    private struct Inputs: Hashable {
        let channelCount: Int
        let favourites: Set<String>
        let lists: [ChannelList]
    }

    var body: some View {
        Group {
            if let channels, channels.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let channels {
                VStack(spacing: 0) {
                    header
                    if isGuide { GuideRuler(windowStart: windowStart, windowLength: Self.windowLength) }
                    // The guide labels follow the clock.
                    TimelineView(.everyMinute) { timeline in
                        List(channels) { channel in
                            row(for: channel, in: channels, now: timeline.date)
                                .focused(focus, equals: .item(channel.id))
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Inputs(channelCount: store.playlist.channels.count, favourites: store.favourites, lists: store.lists)) {
            await load()
        }
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
        }
    }

    @ViewBuilder
    private func row(for channel: Channel, in channels: [Channel], now: Date) -> some View {
        let play = { session = PlayerSession(channels: channels, index: channels.firstIndex(of: channel) ?? 0) }
        if isGuide {
            Button(action: play) {
                GuideRow(
                    name: channel.name,
                    programmes: epg.guide.programmes(channelID: channel.tvgID, from: windowStart, to: windowStart.addingTimeInterval(Self.windowLength)),
                    windowStart: windowStart,
                    windowEnd: windowStart.addingTimeInterval(Self.windowLength),
                    now: now
                )
            }
            .contextMenu {
                MembershipMenu(key: channel.key)
                if let extra = moveMenu(for: channel, in: channels) { extra }
            }
        } else {
            ChannelRow(channel: channel, now: now, extraMenu: moveMenu(for: channel, in: channels), action: play)
        }
    }

    /// Refresh, the List/Guide switch, and in guide mode the controls that move the timeline.
    private var header: some View {
        HStack(spacing: 24) {
            if canShowGuide {
                Button {
                    showsGuide.toggle()
                } label: {
                    Label(showsGuide ? "Show as List" : "Show Guide", systemImage: showsGuide ? "list.bullet" : "calendar")
                }
            }
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isLoading {
                    Label("Updating… \(store.downloadedBytes.formatted(.byteCount(style: .file)))", systemImage: "arrow.clockwise")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isLoading)
            Spacer()
            if isGuide {
                Text(windowStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .foregroundStyle(.secondary)
                Button {
                    windowStart = max(windowStart.addingTimeInterval(-Self.step), Self.currentWindowStart(for: Date()))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(windowStart <= Self.currentWindowStart(for: Date()))
                Button("Now") { windowStart = Self.currentWindowStart(for: Date()) }
                Button {
                    windowStart = windowStart.addingTimeInterval(Self.step)
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var emptyText: String {
        switch filter {
        case .favourites: "No favourites here yet. Hold the select button on a channel to add it."
        case .list: "This list has nothing here yet. Hold the select button on a channel to add it."
        case .group: "Nothing in this group."
        }
    }

    /// Rearranging entries, offered while a list is showing.
    private func moveMenu(for channel: Channel, in channels: [Channel]) -> AnyView? {
        guard case .list(let id) = filter, let index = channels.firstIndex(of: channel) else { return nil }
        return AnyView(Group {
            if index > 0 {
                Button("Move Up") { store.move(channel.key, before: channels[index - 1].key, inList: id) }
                Button("Move to Top") { store.move(channel.key, before: channels[0].key, inList: id) }
            }
            if index < channels.count - 1 {
                Button("Move Down") {
                    store.move(channel.key, before: index + 2 < channels.count ? channels[index + 2].key : nil, inList: id)
                }
            }
        })
    }

    private func load() async {
        let playlist = store.playlist, favourites = store.favourites, kind = kind, filter = filter
        var list: ChannelList?
        if case .list(let id) = filter { list = store.lists.first { $0.id == id } }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [Channel] in
            let members = Set(list?.keys ?? [])
            let found = playlist.channels.filter { channel in
                guard channel.kind == kind else { return false }
                switch filter {
                case .favourites: return favourites.contains(channel.key)
                case .list: return members.contains(channel.key)
                case .group(let group): return channel.group == group
                }
            }
            guard let list else { return found }
            // A list keeps the order its owner gave it.
            let position = Dictionary(list.keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return found.sorted { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }
        }.value
        if Task.isCancelled { return }
        channels = loaded
        if wantsFocus {
            // The rows have to exist before one can take focus, which takes a moment after
            // the list is set; keep asking briefly until it lands.
            if let first = loaded.first {
                for delay in [50, 250, 600] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    if case .item = focus.wrappedValue { break }
                    focus.wrappedValue = .item(first.id)
                }
            }
            wantsFocus = false
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    var title: String?
    let now: Date
    /// Extra context-menu entries, after the favourites and list ones.
    var extraMenu: AnyView?
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
                if store.favourites.contains(channel.key) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .contextMenu {
            MembershipMenu(key: channel.key)
            if let extraMenu { extraMenu }
        }
    }
}
