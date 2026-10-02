import AppKit
import PlayaCore
import SwiftUI

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

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, toggleFavourite: toggleFavourite)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("channel")))
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 38
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView
        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

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
        let favouritesChanged = coordinator.favourites != favourites || coordinator.guideStamp != guideStamp
        coordinator.favourites = favourites
        coordinator.guideStamp = guideStamp
        if coordinator.generation != generation {
            coordinator.generation = generation
            coordinator.channels = channels
            coordinator.reload(selecting: selection)
        } else if coordinator.selectedChannel != selection {
            coordinator.select(selection)
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
        var guideStamp = 0
        var channels: [Channel] = []
        var generation = -1
        weak var tableView: NSTableView?
        private var isUpdatingSelection = false

        init(selection: Binding<Channel?>, toggleFavourite: @escaping (Channel) -> Void) {
            self.selection = selection
            self.toggleFavourite = toggleFavourite
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let row = tableView?.clickedRow, channels.indices.contains(row) else { return }
            let isFavourite = favourites.contains(channels[row].url)
            let item = NSMenuItem(
                title: isFavourite ? "Remove from Favourites" : "Add to Favourites",
                action: #selector(toggleFavouriteForClickedRow),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        @objc private func toggleFavouriteForClickedRow() {
            guard let row = tableView?.clickedRow, channels.indices.contains(row) else { return }
            toggleFavourite(channels[row])
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
            cell.configure(with: channel, title: title(channel), isFavourite: favourites.contains(channel.url), subtitle: subtitle(channel))
            cell.onToggleFavourite = { [weak self] in self?.toggleFavourite(channel) }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            // A reload that drops the playing channel from view must not stop playback.
            guard !isUpdatingSelection, let channel = selectedChannel else { return }
            selection.wrappedValue = channel
        }
    }
}

private final class ChannelCellView: NSTableCellView {
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
        nameField.lineBreakMode = .byTruncatingTail
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

    func configure(with channel: Channel, title: String, isFavourite: Bool, subtitle: String?) {
        nameField.stringValue = title
        subtitleField.stringValue = subtitle ?? ""
        subtitleField.isHidden = subtitle == nil
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
