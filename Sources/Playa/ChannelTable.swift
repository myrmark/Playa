import AppKit
import PlayaCore
import SwiftUI

/// An entry in a row's right-click menu.
struct RowMenuItem {
    var title = ""
    var isOn = false
    var children: [RowMenuItem] = []
    var action: (() -> Void)?
    var isSeparator = false

    static let separator = RowMenuItem(isSeparator: true)
}

/// Channel list backed by NSTableView. SwiftUI's `List` keeps per-row state for
/// every element, which makes swapping a provider-sized playlist (100k+ entries)
/// freeze the app for many seconds; NSTableView only builds the visible rows.
struct ChannelTable: NSViewRepresentable {
    let channels: [Channel]
    /// Bumped whenever `channels` changes, so updates don't have to compare arrays.
    let generation: Int
    let favourites: Set<String>
    /// Changes whenever the text returned by `subtitle` may have changed.
    let guideStamp: Int
    @Binding var selection: Channel?
    let toggleFavourite: (Channel) -> Void
    /// Second line of a row: what the channel is showing now, if known.
    let subtitle: (Channel) -> String?
    /// First line of a row. Episodes show "E03 · Title" instead of the raw playlist name.
    var title: (Channel) -> String = { $0.name }
    /// The right-click menu for a row, or for all selected rows when the clicked one is among them.
    var menu: ([Channel]) -> [RowMenuItem] = { _ in [] }
    /// Days of archive, for channels that keep one; they are marked in the list.
    var catchUpDays: (Channel) -> Int? = { _ in nil }
    /// Set when rows can be dragged into a new order: called with the moved channel and the
    /// channel it should now sit before, or nil for the end.
    var onMove: ((Channel, Channel?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, toggleFavourite: toggleFavourite)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = ActivatingTableView()
        // A single click only selects, so rows can be picked for a list without changing channel.
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.activate)
        tableView.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activate() }
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel")))
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 38
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        // Shift- and Command-click select several rows, to add them to a list in one go.
        tableView.allowsMultipleSelection = true
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu
        tableView.registerForDraggedTypes([Coordinator.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        coordinator.toggleFavourite = toggleFavourite
        coordinator.subtitle = subtitle
        coordinator.title = title
        coordinator.menu = menu
        coordinator.onMove = onMove
        coordinator.catchUpDays = catchUpDays
        let favouritesChanged = coordinator.favourites != favourites || coordinator.guideStamp != guideStamp
        coordinator.favourites = favourites
        coordinator.guideStamp = guideStamp
        let playingChanged = coordinator.playing != selection
        let previous = coordinator.playing
        coordinator.playing = selection
        if coordinator.generation != generation {
            coordinator.generation = generation
            coordinator.channels = channels
            coordinator.reload(selecting: selection)
        } else if playingChanged {
            coordinator.refreshRows(for: [previous, selection])
            // Follow a channel change made elsewhere, such as from the guide. A multiple
            // selection is the user's work in progress; leave it alone.
            if coordinator.selectedChannel != selection, !coordinator.hasMultipleSelection {
                coordinator.select(selection)
            }
        }
        if favouritesChanged, let tableView = coordinator.tableView {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            if let rows = Range(visibleRows) {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: [0])
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var selection: Binding<Channel?>
        var toggleFavourite: (Channel) -> Void
        var favourites: Set<String> = []
        var subtitle: (Channel) -> String? = { _ in nil }
        var title: (Channel) -> String = { $0.name }
        var menu: ([Channel]) -> [RowMenuItem] = { _ in [] }
        var onMove: ((Channel, Channel?) -> Void)?
        var catchUpDays: (Channel) -> Int? = { _ in nil }
        var guideStamp = 0
        static let rowType = NSPasteboard.PasteboardType("com.filipmalmberg.Playa.channel-row")
        var channels: [Channel] = []
        /// The channel on screen, marked in the list; the highlighted row may be another.
        var playing: Channel?
        var generation = -1
        weak var tableView: NSTableView?
        private var isUpdatingSelection = false

        init(selection: Binding<Channel?>, toggleFavourite: @escaping (Channel) -> Void) {
            self.selection = selection
            self.toggleFavourite = toggleFavourite
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, channels.indices.contains(tableView.clickedRow) else { return }
            let selected = tableView.selectedRowIndexes
            // Right-clicking inside a multiple selection acts on all of it, as in Finder.
            let rows = selected.count > 1 && selected.contains(tableView.clickedRow) ? Array(selected) : [tableView.clickedRow]
            fill(menu, with: self.menu(rows.filter(channels.indices.contains).map { channels[$0] }))
        }

        var hasMultipleSelection: Bool {
            (tableView?.selectedRowIndexes.count ?? 0) > 1
        }

        private func fill(_ menu: NSMenu, with items: [RowMenuItem]) {
            for item in items {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.state = item.isOn ? .on : .off
                if !item.children.isEmpty {
                    let submenu = NSMenu()
                    fill(submenu, with: item.children)
                    menuItem.submenu = submenu
                } else if let action = item.action {
                    menuItem.target = self
                    menuItem.action = #selector(runMenuAction(_:))
                    menuItem.representedObject = MenuAction(run: action)
                }
                menu.addItem(menuItem)
            }
        }

        private final class MenuAction {
            let run: () -> Void
            init(run: @escaping () -> Void) { self.run = run }
        }

        @objc private func runMenuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuAction)?.run()
        }

        // MARK: Reordering by drag

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard onMove != nil else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: Self.rowType)
            return item
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard onMove != nil, info.draggingSource as? NSTableView === tableView else { return [] }
            // Rows are dropped between other rows, never onto one.
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let onMove, let source = info.draggingPasteboard.string(forType: Self.rowType).flatMap(Int.init),
                  channels.indices.contains(source), row != source, row != source + 1
            else { return false }
            onMove(channels[source], row < channels.count ? channels[row] : nil)
            return true
        }

        /// Double-click or Return: play the highlighted row.
        @objc func activate() {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard channels.indices.contains(row) else { return }
            selection.wrappedValue = channels[row]
        }

        /// The name as shown: the playing channel carries a marker.
        private func shownTitle(_ channel: Channel) -> String {
            (channel == playing ? "▶ " : "") + title(channel)
        }

        func refreshRows(for changed: [Channel?]) {
            guard let tableView else { return }
            let rows = IndexSet(changed.compactMap { $0 }.compactMap { channels.firstIndex(of: $0) })
            guard !rows.isEmpty else { return }
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            tableView.reloadData(forRowIndexes: rows, columnIndexes: [0])
        }

        var selectedChannel: Channel? {
            guard let row = tableView?.selectedRow, channels.indices.contains(row) else { return nil }
            return channels[row]
        }

        func reload(selecting channel: Channel?) {
            isUpdatingSelection = true
            tableView?.reloadData()
            isUpdatingSelection = false
            select(channel)
            if tableView?.selectedRow == -1 {
                tableView?.scrollRowToVisible(0)
            }
        }

        func select(_ channel: Channel?) {
            guard let tableView else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }
            if let channel, let row = channels.firstIndex(of: channel) {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            } else {
                tableView.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            channels.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("ChannelCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChannelCellView
                ?? ChannelCellView(identifier: identifier)
            let channel = channels[row]
            cell.configure(
                with: channel, title: shownTitle(channel), isFavourite: favourites.contains(channel.key),
                subtitle: subtitle(channel), catchUpDays: catchUpDays(channel), textWidth: textWidth(in: tableView)
            )
            cell.onToggleFavourite = { [weak self] in self?.toggleFavourite(channel) }
            return cell
        }

        private func textWidth(in tableView: NSTableView) -> CGFloat {
            max((tableView.tableColumns.first?.width ?? tableView.bounds.width) - ChannelCellView.nonTextWidth, 60)
        }

        /// Rows grow by a line when the channel's name needs two.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard channels.indices.contains(row) else { return 38 }
            return ChannelCellView.lines(for: shownTitle(channels[row]), textWidth: textWidth(in: tableView)) == 2 ? 54 : 38
        }

        /// Widening or narrowing the sidebar changes which names fit on one line.
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tableView, !channels.isEmpty else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<channels.count))
            }
            let visible = tableView.rows(in: tableView.visibleRect)
            if let rows = Range(visible) {
                tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows), columnIndexes: [0])
            }
        }
    }
}

/// A table that reports Return, which plays the highlighted row.
final class ActivatingTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class ChannelCellView: NSTableCellView {
    private static let placeholder = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
    private static let cache = NSCache<NSString, NSImage>()

    private let logoView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let starView = NSButton()
    /// Called when the row's star is clicked.
    var onToggleFavourite: (() -> Void)?
    private var logoTask: URLSessionDataTask?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.contentTintColor = .tertiaryLabelColor
        // Long names wrap onto a second line before they are cut off.
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byWordWrapping
        nameField.cell?.wraps = true
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        starView.isBordered = false
        starView.imagePosition = .imageOnly
        starView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        starView.target = self
        starView.action = #selector(starClicked)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The stack centres the name vertically when there is no programme line.
        let textStack = NSStackView(views: [nameField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        for view in [logoView, textStack, starView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = logoView
        textField = nameField
        NSLayoutConstraint.activate([
            logoView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            logoView.centerYAnchor.constraint(equalTo: centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 32),
            logoView.heightAnchor.constraint(equalToConstant: 24),
            textStack.leadingAnchor.constraint(equalTo: logoView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: starView.leadingAnchor, constant: -6),
            starView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            starView.centerYAnchor.constraint(equalTo: centerYAnchor),
            starView.widthAnchor.constraint(equalToConstant: 22),
            starView.heightAnchor.constraint(equalToConstant: 22),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func starClicked() {
        onToggleFavourite?()
    }

    /// Room the logo, the star and the row's margins take from the text.
    static let nonTextWidth: CGFloat = 78

    /// How many lines `title` needs in a row whose text area is `textWidth` wide. This is an
    /// estimate from the character count: measuring every name in a provider-sized list each
    /// time it is filtered would make the list stutter.
    static func lines(for title: String, textWidth: CGFloat) -> Int {
        let charactersPerLine = max(Int(textWidth / 7.2), 8)
        return title.count > charactersPerLine ? 2 : 1
    }

    private static let catchUpSymbol: NSTextAttachment = {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Catch-up")?
            .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize, weight: .regular))
        return attachment
    }()

    func configure(with channel: Channel, title: String, isFavourite: Bool, subtitle: String?, catchUpDays: Int? = nil, textWidth: CGFloat) {
        // A wrapping label needs to be told how wide it may get before it works out its height.
        nameField.preferredMaxLayoutWidth = textWidth
        nameField.stringValue = title
        if let catchUpDays {
            // A channel with an archive: a mark before the programme, and the days on hover.
            let line = NSMutableAttributedString(attachment: Self.catchUpSymbol)
            line.append(NSAttributedString(string: " " + (subtitle ?? "Catch-up")))
            line.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor],
                               range: NSRange(location: 0, length: line.length))
            subtitleField.attributedStringValue = line
            subtitleField.isHidden = false
            toolTip = "Catch-up: programmes from the last \(catchUpDays == 1 ? "day" : "\(catchUpDays) days") can be watched"
        } else {
            subtitleField.stringValue = subtitle ?? ""
            subtitleField.isHidden = subtitle == nil
            toolTip = nil
        }
        starView.image = NSImage(
            systemSymbolName: isFavourite ? "star.fill" : "star",
            accessibilityDescription: isFavourite ? "Remove from Favourites" : "Add to Favourites"
        )
        starView.contentTintColor = isFavourite ? .systemYellow : .tertiaryLabelColor
        starView.toolTip = isFavourite ? "Remove from Favourites" : "Add to Favourites"
        logoTask?.cancel()
        logoTask = nil
        logoView.image = Self.placeholder

        guard let logo = channel.logo, let url = URL(string: logo) else { return }
        if let cached = Self.cache.object(forKey: logo as NSString) {
            logoView.image = cached
            return
        }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            Self.cache.setObject(image, forKey: logo as NSString)
            DispatchQueue.main.async {
                // The cell may have been reused for another channel in the meantime.
                guard let self, self.logoTask?.originalRequest?.url == url else { return }
                self.logoView.image = image
            }
        }
        logoTask = task
        task.resume()
    }
}
