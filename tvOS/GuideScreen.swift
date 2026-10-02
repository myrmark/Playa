import PlayaCore
import SwiftUI

/// Programme grid: one row per live channel, time running left to right.
struct GuideScreen: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore

    @State private var filter: ChannelFilter?
    @State private var rows: [Channel] = []
    /// Groups that have at least one channel with programme information.
    @State private var groups: [String] = []
    @State private var windowStart = GuideScreen.currentWindowStart(for: Date())
    @State private var session: PlayerSession?

    static let channelColumnWidth: CGFloat = 420
    private static let windowLength: TimeInterval = 3 * 3600
    private static let step: TimeInterval = 3600

    /// The half hour that `date` falls in.
    private static func currentWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    private var windowEnd: Date { windowStart.addingTimeInterval(Self.windowLength) }

    var body: some View {
        VStack(spacing: 0) {
            if epg.guide.isEmpty {
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                header
                ruler
                TimelineView(.everyMinute) { timeline in
                    List(rows) { channel in
                        Button {
                            session = PlayerSession(channels: rows, index: rows.firstIndex(of: channel) ?? 0)
                        } label: {
                            GuideRow(
                                name: channel.name,
                                programmes: epg.guide.programmes(channelID: channel.tvgID, from: windowStart, to: windowEnd),
                                windowStart: windowStart,
                                windowEnd: windowEnd,
                                now: timeline.date
                            )
                        }
                    }
                }
            }
        }
        .task(id: epg.version) { await load() }
        .onChange(of: filter) { Task { await load() } }
        .fullScreenCover(item: $session) { session in
            PlayerScreen(session: session)
        }
    }

    private var statusText: String {
        switch epg.status {
        case .loading: "Loading the TV guide…"
        case .failed(let message): "The TV guide is unavailable: \(message)"
        case .unavailable, .loaded: "This playlist has no TV guide."
        }
    }

    private var header: some View {
        HStack(spacing: 30) {
            Picker("Channels", selection: $filter) {
                Text("Favourites").tag(ChannelFilter?.some(.favourites))
                ForEach(groups, id: \.self) { group in
                    Text(group).tag(ChannelFilter?.some(.group(group)))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 600, alignment: .leading)

            Spacer()
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
        .padding(.horizontal, 60)
        .padding(.bottom, 20)
    }

    /// Half-hour marks on the same scale the rows draw their programmes with.
    private var ruler: some View {
        GeometryReader { geometry in
            let inset = GuideRow.horizontalInset + Self.channelColumnWidth
            let timelineWidth = max(geometry.size.width - inset - GuideRow.horizontalInset, 1)
            let ticks = Int(Self.windowLength / 1800)
            ForEach(0..<ticks, id: \.self) { tick in
                Text(windowStart.addingTimeInterval(Double(tick) * 1800).formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: inset + timelineWidth * CGFloat(tick) / CGFloat(ticks))
            }
        }
        .frame(height: 44)
    }

    private func load() async {
        let playlist = store.playlist, favourites = store.favourites, guide = epg.guide
        let current = filter
        let result = await Task.detached(priority: .userInitiated) { () -> (groups: [String], filter: ChannelFilter?, rows: [Channel]) in
            let listed = playlist.channels.filter { channel in
                channel.kind == .live && channel.tvgID.map { guide.programmes[$0.lowercased()] != nil } == true
            }
            let withGuide = Set(listed.map(\.group))
            let groups = (playlist.groupsByKind[.live] ?? []).filter(withGuide.contains)
            // Open on favourites when there are any, otherwise on the first group.
            let filter = current ?? (listed.contains { favourites.contains($0.key) } ? .favourites : groups.first.map(ChannelFilter.group))
            let rows = listed.filter { channel in
                switch filter {
                case .favourites: favourites.contains(channel.key)
                case .group(let group): channel.group == group
                case nil: false
                }
            }
            return (groups, filter, rows)
        }.value
        groups = result.groups
        rows = result.rows
        if filter != result.filter { filter = result.filter }
    }
}

/// One channel's name and its programmes as blocks along the time axis.
private struct GuideRow: View {
    let name: String
    let programmes: ArraySlice<Programme>
    let windowStart: Date
    let windowEnd: Date
    let now: Date

    /// Space the list leaves on each side of a row's content, inside the screen's safe area.
    static let horizontalInset: CGFloat = 20

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        // A focused row turns light, so its contents switch to dark.
        let ink: Color = isFocused ? .black : .white
        HStack(spacing: 0) {
            Text(name)
                .lineLimit(1)
                .frame(width: GuideScreen.channelColumnWidth - 20, alignment: .leading)
                .padding(.trailing, 20)
            Canvas { context, size in
                let span = windowEnd.timeIntervalSince(windowStart)
                func x(_ date: Date) -> CGFloat {
                    size.width * CGFloat(min(max(date.timeIntervalSince(windowStart) / span, 0), 1))
                }
                for programme in programmes {
                    let block = CGRect(x: x(programme.start) + 2, y: 4, width: max(x(programme.stop) - x(programme.start) - 4, 0), height: size.height - 8)
                    guard block.width > 2 else { continue }
                    let isOnNow = programme.start <= now && now < programme.stop
                    context.fill(
                        Path(roundedRect: block, cornerRadius: 10),
                        with: .color(isOnNow ? Color.accentColor.opacity(isFocused ? 0.45 : 0.4) : ink.opacity(0.1))
                    )
                    guard block.width > 60 else { continue }
                    var text = context
                    text.clip(to: Path(block.insetBy(dx: 12, dy: 0)))
                    text.draw(
                        Text(programme.title).font(.caption).foregroundStyle(ink),
                        at: CGPoint(x: block.minX + 14, y: block.minY + 10), anchor: .topLeading
                    )
                    text.draw(
                        Text(programme.start.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(ink.opacity(0.6)),
                        at: CGPoint(x: block.minX + 14, y: block.maxY - 10), anchor: .bottomLeading
                    )
                }
                if windowStart <= now, now < windowEnd {
                    context.fill(Path(CGRect(x: x(now) - 2, y: 0, width: 4, height: size.height)), with: .color(.red))
                }
            }
        }
        .frame(height: 96)
    }
}
