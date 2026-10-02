import PlayaCore
import SwiftUI

/// The channels or films in Favourites, Recently Watched, a list or a group.
struct ChannelListView: View {
    let kind: ChannelKind
    let filter: BrowseFilter

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var channels: [Channel]?
    @State private var session: PlayerSession?
    /// Whether Live TV shows each channel's schedule as a timeline instead of a plain list.
    @AppStorage("liveShowsGuide") private var showsGuide = false
    @State private var windowStart = ChannelListView.currentWindowStart(for: Date())

    private static let step: TimeInterval = 3600

    /// The half hour that `date` falls in.
    private static func currentWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    /// A phone in portrait has room for an hour and a half; wider screens for three hours.
    private var windowLength: TimeInterval { sizeClass == .regular ? 3 * 3600 : 1.5 * 3600 }
    private var nameWidth: CGFloat { sizeClass == .regular ? 200 : 96 }
    private var canShowGuide: Bool { kind == .live && !epg.guide.isEmpty }
    private var isGuide: Bool { canShowGuide && showsGuide }

    /// Everything the list depends on, so it reloads when any of it changes.
    private struct Inputs: Hashable {
        let channelCount: Int
        let favourites: Set<String>
        let lists: [ChannelList]
        let recents: [String]
    }

    var body: some View {
        Group {
            if let channels, channels.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyText))
            } else if let channels {
                VStack(spacing: 0) {
                    if isGuide { guideControls }
                    // The guide labels follow the clock.
                    TimelineView(.everyMinute) { timeline in
                        List {
                            ForEach(channels) { channel in
                                row(for: channel, in: channels, now: timeline.date)
                            }
                            .onMove(perform: moveHandler(in: channels))
                        }
                        .listStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(filter.title(in: store))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canShowGuide {
                    Button {
                        showsGuide.toggle()
                    } label: {
                        Label(showsGuide ? "Show as List" : "Show Guide", systemImage: showsGuide ? "list.bullet" : "calendar")
                    }
                }
                if store.isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task(id: Inputs(channelCount: store.playlist.channels.count, favourites: store.favourites, lists: store.lists, recents: store.recents)) {
            await load()
        }
        .fullScreenCover(item: $session) { session in
            PlayerView(session: session)
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .favourites: "No favourites here yet"
        case .recent: "Nothing watched here yet"
        case .list: "This list is empty here"
        case .group: "Nothing in this group"
        }
    }

    private var emptyText: String {
        switch filter {
        case .favourites, .list: "Touch and hold a channel elsewhere to add it."
        case .recent: "What you watch for more than a few seconds shows up here."
        case .group: ""
        }
    }

    @ViewBuilder
    private func row(for channel: Channel, in channels: [Channel], now: Date) -> some View {
        let play = { session = PlayerSession(channels: channels, index: channels.firstIndex(of: channel) ?? 0) }
        Group {
            if isGuide {
                Button(action: play) {
                    TimelineRow(
                        name: channel.name,
                        nameWidth: nameWidth,
                        programmes: epg.guide.programmes(channelID: channel.tvgID, from: windowStart, to: windowStart.addingTimeInterval(windowLength)),
                        windowStart: windowStart,
                        windowEnd: windowStart.addingTimeInterval(windowLength),
                        now: now
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
            } else {
                ChannelRow(channel: channel, now: now, action: play)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.toggleFavourite(channel)
            } label: {
                Label("Favourite", systemImage: store.favourites.contains(channel.key) ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            if case .list(let id) = filter {
                Button("Remove", role: .destructive) { store.toggle(channel.key, inList: id) }
            }
        }
        .contextMenu {
            MembershipMenu(key: channel.key)
        }
    }

    /// Dragging rows rearranges a list. Other filters follow the playlist's order.
    private func moveHandler(in channels: [Channel]) -> ((IndexSet, Int) -> Void)? {
        guard case .list(let id) = filter else { return nil }
        return { source, destination in
            let before = destination < channels.count ? channels[destination].key : nil
            for index in source {
                store.move(channels[index].key, before: before, inList: id)
            }
        }
    }

    /// The date and the buttons that move the guide's timeline, above a ruler of half-hour marks.
    private var guideControls: some View {
        VStack(spacing: 4) {
            HStack {
                Text(windowStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            TimelineRuler(windowStart: windowStart, windowLength: windowLength, nameWidth: nameWidth)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func load() async {
        let playlist = store.playlist, favourites = store.favourites, kind = kind, filter = filter
        // Lists and Recently Watched have an order of their own; everything else follows the playlist.
        var ordered: [String]?
        if case .list(let id) = filter { ordered = store.lists.first { $0.id == id }?.keys }
        if filter == .recent { ordered = store.recents }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [Channel] in
            let members = Set(ordered ?? [])
            let found = playlist.channels.filter { channel in
                guard channel.kind == kind else { return false }
                switch filter {
                case .favourites: return favourites.contains(channel.key)
                case .list, .recent: return members.contains(channel.key)
                case .group(let group): return channel.group == group
                }
            }
            guard let ordered else { return found }
            let position = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return found.sorted { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }
        }.value
        if !Task.isCancelled { channels = loaded }
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
            HStack(spacing: 12) {
                AsyncImage(url: channel.logo.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: channel.kind == .live ? "tv" : "film")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 44, height: 30)

                VStack(alignment: .leading, spacing: 2) {
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
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Half-hour marks on the same scale `TimelineRow` draws its programmes with.
struct TimelineRuler: View {
    let windowStart: Date
    let windowLength: TimeInterval
    let nameWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let timelineWidth = max(geometry.size.width - nameWidth, 1)
            let ticks = Int(windowLength / 1800)
            ForEach(0..<ticks, id: \.self) { tick in
                Text(windowStart.addingTimeInterval(Double(tick) * 1800).formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: nameWidth + timelineWidth * CGFloat(tick) / CGFloat(ticks))
            }
        }
        .frame(height: 16)
    }
}

/// One channel's name and its programmes as blocks along the time axis.
struct TimelineRow: View {
    let name: String
    let nameWidth: CGFloat
    let programmes: ArraySlice<Programme>
    let windowStart: Date
    let windowEnd: Date
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .font(.subheadline)
                .lineLimit(2)
                .frame(width: nameWidth - 8, alignment: .leading)
                .padding(.trailing, 8)
            Canvas { context, size in
                let span = windowEnd.timeIntervalSince(windowStart)
                func x(_ date: Date) -> CGFloat {
                    size.width * CGFloat(min(max(date.timeIntervalSince(windowStart) / span, 0), 1))
                }
                if programmes.isEmpty {
                    context.draw(
                        Text("No programme information").font(.caption).foregroundStyle(.tertiary),
                        at: CGPoint(x: 6, y: size.height / 2), anchor: .leading
                    )
                }
                for programme in programmes {
                    let block = CGRect(x: x(programme.start) + 1, y: 2, width: max(x(programme.stop) - x(programme.start) - 2, 0), height: size.height - 4)
                    guard block.width > 2 else { continue }
                    let isOnNow = programme.start <= now && now < programme.stop
                    context.fill(
                        Path(roundedRect: block, cornerRadius: 6),
                        with: .color(isOnNow ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08))
                    )
                    guard block.width > 34 else { continue }
                    var text = context
                    text.clip(to: Path(block.insetBy(dx: 5, dy: 0)))
                    text.draw(
                        Text(programme.title).font(.caption).fontWeight(.medium),
                        at: CGPoint(x: block.minX + 6, y: block.minY + 5), anchor: .topLeading
                    )
                    text.draw(
                        Text(programme.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary),
                        at: CGPoint(x: block.minX + 6, y: block.maxY - 5), anchor: .bottomLeading
                    )
                }
                if windowStart <= now, now < windowEnd {
                    context.fill(Path(CGRect(x: x(now) - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
                }
            }
        }
        .frame(height: 46)
        .contentShape(Rectangle())
    }
}
