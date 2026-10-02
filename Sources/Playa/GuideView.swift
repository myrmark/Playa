import AppKit
import PlayaCore
import SwiftUI

/// Full-window programme grid: one row per live channel, time running left to right.
struct GuideView: View {
    let playlist: Playlist
    let guide: Guide
    let favourites: Set<String>
    let lists: [ChannelList]
    let recents: [String]
    let hiddenGroups: Set<String>
    let now: Date
    let playingChannel: Channel?
    let onPlay: (Channel) -> Void
    let onClose: () -> Void

    @State private var filter: ChannelFilter
    @State private var onlyWithProgrammes = true
    @State private var windowStart: Date
    @State private var rows: [Channel] = []
    @State private var rowGeneration = 0
    @State private var searchText = ""
    /// While searching: the first matching programme per guide channel id, from now on.
    @State private var searchHits: [String: Programme] = [:]

    /// Searching takes at least three letters, as it does in the sidebar.
    private var query: String {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 ? trimmed : ""
    }

    static let channelColumnWidth: CGFloat = 220
    private static let windowLength: TimeInterval = 4 * 3600
    private static let step: TimeInterval = 2 * 3600

    init(
        playlist: Playlist, guide: Guide, favourites: Set<String>, lists: [ChannelList], recents: [String], hiddenGroups: Set<String>, now: Date,
        initialFilter: ChannelFilter,
        playingChannel: Channel?, onPlay: @escaping (Channel) -> Void, onClose: @escaping () -> Void
    ) {
        self.playlist = playlist
        self.guide = guide
        self.favourites = favourites
        self.lists = lists
        self.recents = recents
        self.hiddenGroups = hiddenGroups
        self.now = now
        self.playingChannel = playingChannel
        self.onPlay = onPlay
        self.onClose = onClose
        _filter = State(initialValue: initialFilter)
        _windowStart = State(initialValue: Self.currentWindowStart(for: now))
    }

    /// The half hour that `date` falls in.
    private static func currentWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
    }

    private var windowEnd: Date { windowStart.addingTimeInterval(Self.windowLength) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timeRuler
            Divider()
            GuideTable(
                rows: rows,
                guide: guide,
                windowStart: windowStart,
                windowEnd: windowEnd,
                now: now,
                playingURL: playingChannel?.url,
                highlight: query,
                stamp: rowGeneration &* 1_000_003 &+ Int(windowStart.timeIntervalSince1970 / 60) &+ Int(now.timeIntervalSince1970 / 60),
                onPlay: onPlay
            )
            .overlay {
                if rows.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "No channels to show",
                        systemImage: "calendar",
                        description: Text(filter == .favourites
                            ? "None of your favourites have programme information. Choose another group above."
                            : "This group has no programme information.")
                    )
                }
            }
        }
        .background(.background)
        .onAppear(perform: updateRows)
        .onChange(of: filter) { updateRows() }
        .onChange(of: onlyWithProgrammes) { updateRows() }
        .task(id: query) { await search() }
    }

    /// Finds the channels showing a matching programme in the next day and a half, lists
    /// them soonest first, and moves the timeline to the first one if it is out of view.
    private func search() async {
        let query = query, guide = guide, now = now
        guard !query.isEmpty else {
            if !searchHits.isEmpty {
                searchHits = [:]
                updateRows()
            }
            return
        }
        // Wait for a pause in typing.
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let hits = await Task.detached(priority: .userInitiated) {
            guide.search(query, from: now, horizon: 36 * 3600)
        }.value
        if Task.isCancelled { return }
        searchHits = hits
        updateRows()
        let starts = rows.compactMap { $0.tvgID.flatMap { hits[$0.lowercased()] }?.start }
        if let first = starts.min(), first >= windowEnd || first < windowStart {
            windowStart = max(Self.currentWindowStart(for: first), Self.currentWindowStart(for: now))
        }
    }

    private func updateRows() {
        // Lists and Recently Watched have an order of their own.
        var ordered: [String]?
        if case .list(let id) = filter { ordered = lists.first { $0.id == id }?.keys }
        if filter == .recent { ordered = recents }
        let members = Set(ordered ?? [])
        rows = playlist.channels.filter { channel in
            guard channel.kind == .live else { return false }
            switch filter {
            case .all: guard !hiddenGroups.contains(PlaylistStore.hiddenKey(group: channel.group, kind: .live)) else { return false }
            case .favourites: guard favourites.contains(channel.key) else { return false }
            case .list, .recent: guard members.contains(channel.key) else { return false }
            case .group(let group): guard channel.group == group else { return false }
            }
            if onlyWithProgrammes {
                guard let id = channel.tvgID, guide.programmes[id.lowercased()] != nil else { return false }
            }
            if !query.isEmpty {
                let showsMatch = channel.tvgID.map { searchHits[$0.lowercased()] != nil } ?? false
                let nameMatches = channel.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                guard showsMatch || nameMatches else { return false }
            }
            return true
        }
        if !query.isEmpty {
            // Soonest matching programme first; channels matched only by name go last.
            func start(_ channel: Channel) -> Date {
                channel.tvgID.flatMap { searchHits[$0.lowercased()] }?.start ?? .distantFuture
            }
            rows = rows.enumerated().sorted { (start($0.element), $0.offset) < (start($1.element), $1.offset) }.map(\.element)
            rowGeneration += 1
            return
        }
        if let ordered {
            let position = Dictionary(ordered.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            rows.sort { (position[$0.key] ?? 0) < (position[$1.key] ?? 0) }
        }
        rowGeneration += 1
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("TV Guide")
                .font(.title3.bold())
            Picker("Channels", selection: $filter) {
                Text("All channels").tag(ChannelFilter.all)
                Label("Favourites", systemImage: "star.fill").tag(ChannelFilter.favourites)
                Label("Recently Watched", systemImage: "clock").tag(ChannelFilter.recent)
                ForEach(lists) { list in
                    Label(list.name, systemImage: "list.bullet").tag(ChannelFilter.list(list.id))
                }
                Divider()
                ForEach((playlist.groupsByKind[.live] ?? []).filter { !hiddenGroups.contains(PlaylistStore.hiddenKey(group: $0, kind: .live)) }, id: \.self) { group in
                    Text(group).tag(ChannelFilter.group(group))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            Toggle("Only channels with a schedule", isOn: $onlyWithProgrammes)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search programmes", text: $searchText)
                    .textFieldStyle(.plain)
                    .onExitCommand { searchText = "" }
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
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 220)

            Spacer()

            Text(windowStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .foregroundStyle(.secondary)
            ControlGroup {
                Button {
                    windowStart = max(windowStart.addingTimeInterval(-Self.step), Self.currentWindowStart(for: now))
                } label: {
                    Label("Earlier", systemImage: "chevron.left")
                }
                .disabled(windowStart <= Self.currentWindowStart(for: now))
                Button("Now") { windowStart = Self.currentWindowStart(for: now) }
                Button {
                    windowStart = windowStart.addingTimeInterval(Self.step)
                } label: {
                    Label("Later", systemImage: "chevron.right")
                }
            }
            .fixedSize()
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Half-hour marks, laid out on the same scale the rows draw their programmes with.
    private var timeRuler: some View {
        GeometryReader { geometry in
            let timelineWidth = max(geometry.size.width - Self.channelColumnWidth, 1)
            let ticks = Int(Self.windowLength / 1800)
            ForEach(0..<ticks, id: \.self) { tick in
                Text(windowStart.addingTimeInterval(Double(tick) * 1800).formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .frame(height: geometry.size.height)
                    .offset(x: Self.channelColumnWidth + timelineWidth * CGFloat(tick) / CGFloat(ticks))
            }
        }
        .frame(height: 24)
    }
}

private struct GuideTable: NSViewRepresentable {
    let rows: [Channel]
    let guide: Guide
    let windowStart: Date
    let windowEnd: Date
    let now: Date
    let playingURL: String?
    /// Programmes mentioning this are outlined; empty for none.
    let highlight: String
    /// Changes whenever anything the rows draw has changed.
    let stamp: Int
    let onPlay: (Channel) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("guide"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.rowHeight = 46
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked)
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        // Overlay scrollers keep the rows exactly as wide as the time ruler above them.
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        if previous.stamp != stamp || previous.playingURL != playingURL || previous.highlight != highlight || coordinator.needsInitialLoad {
            coordinator.needsInitialLoad = false
            coordinator.tableView?.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: GuideTable
        var needsInitialLoad = true
        weak var tableView: NSTableView?

        init(_ parent: GuideTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("GuideRow")
            let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? GuideRowView ?? {
                let view = GuideRowView()
                view.identifier = identifier
                return view
            }()
            let channel = parent.rows[row]
            view.configure(
                name: channel.name,
                programmes: parent.guide.programmes(channelID: channel.tvgID, from: parent.windowStart, to: parent.windowEnd),
                windowStart: parent.windowStart,
                windowEnd: parent.windowEnd,
                now: parent.now,
                isPlaying: channel.url == parent.playingURL,
                highlight: parent.highlight
            )
            return view
        }

        @objc func rowClicked() {
            guard let row = tableView?.clickedRow, parent.rows.indices.contains(row) else { return }
            parent.onPlay(parent.rows[row])
        }
    }
}

/// Draws one channel's name and its programmes as blocks along the time axis.
private final class GuideRowView: NSView {
    private var name = ""
    private var programmes: ArraySlice<Programme> = []
    private var windowStart = Date()
    private var windowEnd = Date()
    private var now = Date()
    private var isPlaying = false
    private var highlight = ""

    private func isHighlighted(_ programme: Programme) -> Bool {
        guard !highlight.isEmpty else { return false }
        return programme.title.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || programme.description?.range(of: highlight, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    override var isFlipped: Bool { true }

    func configure(
        name: String, programmes: ArraySlice<Programme>, windowStart: Date, windowEnd: Date, now: Date, isPlaying: Bool,
        highlight: String
    ) {
        self.highlight = highlight
        self.name = name
        self.programmes = programmes
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.now = now
        self.isPlaying = isPlaying
        needsDisplay = true
        updateToolTips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        updateToolTips()
    }

    private func x(for date: Date) -> CGFloat {
        let columnWidth = GuideView.channelColumnWidth
        let fraction = date.timeIntervalSince(windowStart) / windowEnd.timeIntervalSince(windowStart)
        return columnWidth + (bounds.width - columnWidth) * CGFloat(min(max(fraction, 0), 1))
    }

    private func rect(for programme: Programme) -> NSRect {
        let left = x(for: programme.start)
        let right = x(for: programme.stop)
        return NSRect(x: left + 1, y: 2, width: max(right - left - 2, 0), height: bounds.height - 4)
    }

    /// Hover text per tooltip area. AppKit doesn't keep a tooltip's owner alive, so the row
    /// owns its tooltips itself and looks the text up when asked.
    private var toolTipTexts: [NSView.ToolTipTag: String] = [:]

    private func updateToolTips() {
        removeAllToolTips()
        toolTipTexts.removeAll()
        for programme in programmes {
            let times = "\(programme.start.formatted(date: .omitted, time: .shortened))–\(programme.stop.formatted(date: .omitted, time: .shortened))"
            let tag = addToolTip(rect(for: programme), owner: self, userData: nil)
            toolTipTexts[tag] = [programme.title, times, programme.description].compactMap { $0 }.joined(separator: "\n")
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        toolTipTexts[tag] ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail

        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: isPlaying ? .semibold : .regular),
            .foregroundColor: isPlaying ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        let nameHeight = ceil(NSFont.systemFont(ofSize: NSFont.systemFontSize).boundingRectForFont.height)
        (name as NSString).draw(
            in: NSRect(x: 12, y: (bounds.height - nameHeight) / 2, width: GuideView.channelColumnWidth - 20, height: nameHeight),
            withAttributes: nameAttributes
        )

        if programmes.isEmpty {
            ("No programme information" as NSString).draw(
                at: NSPoint(x: GuideView.channelColumnWidth + 8, y: (bounds.height - nameHeight) / 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.tertiaryLabelColor]
            )
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: truncating,
        ]
        for programme in programmes {
            let block = rect(for: programme)
            guard block.width > 1 else { continue }
            let isOnNow = programme.start <= now && now < programme.stop
            (isOnNow ? NSColor.controlAccentColor.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5).fill()
            if isHighlighted(programme) {
                // What the search found stands out with an outline.
                NSColor.systemYellow.setStroke()
                let outline = NSBezierPath(roundedRect: block.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                outline.lineWidth = 2
                outline.stroke()
            }

            let text = block.insetBy(dx: 7, dy: 0)
            guard text.width > 14 else { continue }
            (programme.title as NSString).draw(
                in: NSRect(x: text.minX, y: block.minY + 5, width: text.width, height: 16),
                withAttributes: titleAttributes
            )
            // A programme that began before the visible window still shows its real start time.
            (programme.start.formatted(date: .omitted, time: .shortened) as NSString).draw(
                in: NSRect(x: text.minX, y: block.minY + 22, width: text.width, height: 14),
                withAttributes: timeAttributes
            )
        }

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        if windowStart <= now && now < windowEnd {
            NSColor.systemRed.setFill()
            NSRect(x: x(for: now) - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}
