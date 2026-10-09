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
    /// The channel's archive, when it keeps one; past programmes on it can be watched.
    let catchUp: (Channel) -> CatchUp?
    /// How many days back the longest archive reaches, which is how far back the guide goes.
    let archiveDays: Int
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
        playingChannel: Channel?, catchUp: @escaping (Channel) -> CatchUp? = { _ in nil }, archiveDays: Int = 0,
        onPlay: @escaping (Channel) -> Void, onClose: @escaping () -> Void
    ) {
        self.catchUp = catchUp
        self.archiveDays = archiveDays
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
    /// The earliest the guide can show: now, or as far back as an archive reaches.
    private var earliestStart: Date {
        Self.currentWindowStart(for: now.addingTimeInterval(-Double(archiveDays) * 86_400))
    }

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
                catchUp: catchUp,
                onShift: { halfHours in
                    let moved = windowStart.addingTimeInterval(Double(halfHours) * 1800)
                    windowStart = max(moved, earliestStart)
                },
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

    /// One row when the window is wide enough for it, otherwise two.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                headerTitle
                channelPicker
                scheduleToggle
                searchField
                Spacer()
                dayLabel
                timeButtons
                doneButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    headerTitle
                    channelPicker
                    Spacer()
                    timeButtons
                    doneButton
                }
                HStack(spacing: 12) {
                    searchField
                    scheduleToggle
                    Spacer()
                    dayLabel
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerTitle: some View {
        Text("TV Guide")
            .font(.title3.bold())
            .fixedSize()
    }

    private var channelPicker: some View {
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
    }

    private var scheduleToggle: some View {
        Toggle("Only channels with a schedule", isOn: $onlyWithProgrammes)
            .fixedSize()
    }

    private var searchField: some View {
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
    }

    private var dayLabel: some View {
        Text(windowStart.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var timeButtons: some View {
        ControlGroup {
            Button {
                windowStart = max(windowStart.addingTimeInterval(-Self.step), earliestStart)
            } label: {
                Label("Earlier", systemImage: "chevron.left")
            }
            .help(archiveDays > 0 ? "Earlier programmes; those on channels with catch-up can be watched" : "Earlier")
            .disabled(windowStart <= earliestStart)
            Button("Now") { windowStart = Self.currentWindowStart(for: now) }
            Button {
                windowStart = windowStart.addingTimeInterval(Self.step)
            } label: {
                Label("Later", systemImage: "chevron.right")
            }
        }
        .fixedSize()
    }

    private var doneButton: some View {
        Button("Done", action: onClose)
            .keyboardShortcut(.cancelAction)
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
    let catchUp: (Channel) -> CatchUp?
    /// Moves the time window by this many half hours, for sideways swipes on the trackpad.
    let onShift: (Int) -> Void
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

        let scrollView = SwipeScrollView()
        scrollView.onShift = { [weak coordinator = context.coordinator] in coordinator?.parent.onShift($0) }
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
                highlight: parent.highlight,
                catchUp: parent.catchUp(channel)
            )
            return view
        }

        /// A past programme on a channel with an archive plays the recording; anything else
        /// plays the channel.
        @objc func rowClicked() {
            guard let tableView, parent.rows.indices.contains(tableView.clickedRow) else { return }
            let channel = parent.rows[tableView.clickedRow]
            if let event = NSApp.currentEvent,
               let rowView = tableView.view(atColumn: 0, row: tableView.clickedRow, makeIfNecessary: false) as? GuideRowView,
               let programme = rowView.programme(at: rowView.convert(event.locationInWindow, from: nil)),
               programme.stop <= parent.now,
               let catchUp = parent.catchUp(channel),
               let recording = channel.archived(programme, catchUp: catchUp, now: parent.now) {
                parent.onPlay(recording)
            } else {
                parent.onPlay(channel)
            }
        }
    }
}

/// Scrolls the rows up and down as usual, and turns sideways trackpad swipes into moves along
/// the time axis, half an hour at a time.
private final class SwipeScrollView: NSScrollView {
    var onShift: ((Int) -> Void)?
    private var sideways: CGFloat = 0
    private var isSwipingSideways = false
    /// Points of sideways travel per half hour.
    private let stepDistance: CGFloat = 50

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            sideways = 0
            isSwipingSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        // Momentum after the fingers lift would carry the guide hours past where it was aimed.
        guard event.hasPreciseScrollingDeltas, isSwipingSideways || (event.phase.isEmpty && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY))
        else {
            if event.momentumPhase.isEmpty || !isSwipingSideways { super.scrollWheel(with: event) }
            return
        }
        guard event.momentumPhase.isEmpty else { return }
        sideways += event.scrollingDeltaX
        // Fingers moving left reveal what comes later, as with a page.
        let steps = Int(sideways / stepDistance)
        if steps != 0 {
            sideways -= CGFloat(steps) * stepDistance
            onShift?(-steps)
        }
        if event.phase == .ended || event.phase == .cancelled { isSwipingSideways = false }
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
    private var catchUp: CatchUp?

    /// Whether a past programme can be watched from the channel's archive.
    private func isWatchable(_ programme: Programme) -> Bool {
        programme.stop <= now && catchUp?.covers(programme.start, now: now) == true
    }

    func programme(at point: NSPoint) -> Programme? {
        programmes.first { rect(for: $0).contains(point) }
    }

    private func isHighlighted(_ programme: Programme) -> Bool {
        guard !highlight.isEmpty else { return false }
        return SearchTerm(highlight).matches(programme)
    }

    override var isFlipped: Bool { true }

    func configure(
        name: String, programmes: ArraySlice<Programme>, windowStart: Date, windowEnd: Date, now: Date, isPlaying: Bool,
        highlight: String, catchUp: CatchUp?
    ) {
        self.catchUp = catchUp
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
            let hint = isWatchable(programme) ? "Click to watch it from the archive" : nil
            toolTipTexts[tag] = [programme.title, times, programme.description, hint].compactMap { $0 }.joined(separator: "\n")
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
            let isPast = programme.stop <= now
            // Past programmes are faint, unless they can still be watched from the archive.
            (isOnNow ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : NSColor.labelColor.withAlphaComponent(isPast && !isWatchable(programme) ? 0.03 : 0.07)).setFill()
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
            var attributes = titleAttributes
            if isPast, !isWatchable(programme) { attributes[.foregroundColor] = NSColor.tertiaryLabelColor }
            ((isWatchable(programme) ? "↺ " + programme.title : programme.title) as NSString).draw(
                in: NSRect(x: text.minX, y: block.minY + 5, width: text.width, height: 16),
                withAttributes: attributes
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
