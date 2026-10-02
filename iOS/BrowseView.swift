import PlayaCore
import SwiftUI

enum BrowseFilter: Hashable {
    case favourites
    case recent
    case list(UUID)
    case group(String)

    /// For remembering which one was open.
    var storageValue: String {
        switch self {
        case .favourites: "favourites"
        case .recent: "recent"
        case .list(let id): "list:\(id.uuidString)"
        case .group(let name): "group:\(name)"
        }
    }

    init?(storageValue: String) {
        if storageValue == "favourites" {
            self = .favourites
        } else if storageValue == "recent" {
            self = .recent
        } else if storageValue.hasPrefix("list:"), let id = UUID(uuidString: String(storageValue.dropFirst(5))) {
            self = .list(id)
        } else if storageValue.hasPrefix("group:") {
            self = .group(String(storageValue.dropFirst(6)))
        } else {
            return nil
        }
    }
}

/// One of the Live TV, Films and Series tabs: Favourites, lists and groups in a sidebar,
/// and what the chosen one holds beside it (or after it, on an iPhone).
struct BrowseView: View {
    let kind: ChannelKind

    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var listEditor: ListEditor
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage private var lastFilter: String
    @State private var selection: BrowseFilter?
    @State private var listToDelete: ChannelList?

    init(kind: ChannelKind) {
        self.kind = kind
        _lastFilter = AppStorage(wrappedValue: "", "lastFilter.\(kind.rawValue)")
    }

    private var groups: [String] { store.visibleGroups(kind) }

    var body: some View {
        NavigationSplitView {
            Group {
                if store.playlist.groupsByKind[kind] == nil {
                    PlaylistLoadingView()
                } else {
                    sidebar
                }
            }
            .navigationTitle(kind.title)
        } detail: {
            if let selection {
                NavigationStack {
                    detail(for: selection)
                        .navigationDestination(for: SeriesShow.self) { EpisodeListView(show: $0) }
                }
                // A fresh stack per filter, so a show opened under another one doesn't linger.
                .id(selection)
            } else {
                ContentUnavailableView("Choose a list or group", systemImage: kind.symbol)
            }
        }
        .onAppear(perform: restoreSelection)
        .onChange(of: groups) { restoreSelection() }
        .onChange(of: selection) { _, selection in
            if let selection { lastFilter = selection.storageValue }
        }
        .confirmationDialog(
            "Delete the list “\(listToDelete?.name ?? "")”?",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = listToDelete?.id { store.deleteList(id) }
            }
        } message: {
            Text("The channels in it are not affected. The list is removed from your other devices too.")
        }
    }

    /// On an iPad the side-by-side layout opens on what was showing last time. On an iPhone
    /// that would push straight past the sidebar, so it starts on the sidebar there.
    private func restoreSelection() {
        if case .group(let name) = selection, !groups.contains(name) { selection = nil }
        guard selection == nil, sizeClass == .regular, store.playlist.groupsByKind[kind] != nil else { return }
        switch BrowseFilter(storageValue: lastFilter) {
        case .list(let id)? where store.lists.contains { $0.id == id }: selection = .list(id)
        case .group(let name)? where groups.contains(name): selection = .group(name)
        case .favourites?: selection = .favourites
        case .recent?: selection = .recent
        default: selection = store.favourites.isEmpty ? groups.first.map(BrowseFilter.group) : .favourites
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Favourites", systemImage: "star.fill").tag(BrowseFilter.favourites)
                Label("Recently Watched", systemImage: "clock").tag(BrowseFilter.recent)
                ForEach(store.lists) { list in
                    Label(list.name, systemImage: "list.bullet")
                        .tag(BrowseFilter.list(list.id))
                        .swipeActions {
                            Button("Delete", role: .destructive) { listToDelete = list }
                            Button("Rename") { listEditor.request = .rename(list) }
                        }
                        .contextMenu {
                            Button("Rename…") { listEditor.request = .rename(list) }
                            Button("Delete List", role: .destructive) { listToDelete = list }
                        }
                }
                Button {
                    listEditor.request = .new(adding: nil)
                } label: {
                    Label("New List…", systemImage: "plus")
                }
            }
            Section("Groups") {
                ForEach(groups, id: \.self) { group in
                    Text(group)
                        .tag(BrowseFilter.group(group))
                        .swipeActions {
                            // Hidden groups come back from Settings → Groups.
                            Button("Hide") { store.setHidden(true, groups: [group], kind: kind) }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func detail(for filter: BrowseFilter) -> some View {
        if kind == .series {
            ShowListView(filter: filter)
        } else {
            ChannelListView(kind: kind, filter: filter)
        }
    }
}

extension BrowseFilter {
    @MainActor
    func title(in store: PlaylistStore) -> String {
        switch self {
        case .favourites: "Favourites"
        case .recent: "Recently Watched"
        case .list(let id): store.lists.first { $0.id == id }?.name ?? "List"
        case .group(let name): name
        }
    }
}
