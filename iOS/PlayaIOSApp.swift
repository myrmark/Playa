import AVFoundation
import PlayaCore
import SwiftUI

@main
struct PlayaIOSApp: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var epg = EPGStore()
    @StateObject private var resume = ResumeStore()
    @StateObject private var player = MPVPlayer()
    @StateObject private var listEditor = ListEditor()
    @StateObject private var following = FollowingStore()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // The app's content isn't even created until the PIN has been entered.
                if lock.isLocked {
                    LockScreen()
                } else {
                    RootView()
                }
            }
            .environmentObject(lock)
            // Leaving the app locks it again, so it can't be picked up where it was left.
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { lock.lock() }
            }
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(resume)
                .environmentObject(player)
                .environmentObject(listEditor)
                .environmentObject(following)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var listEditor: ListEditor
    @State private var listName = ""

    var body: some View {
        Group {
            if store.saved.isEmpty {
                NavigationStack {
                    AddPlaylistView()
                }
            } else {
                TabView {
                    ForEach(ChannelKind.allCases.filter { store.playlist.countByKind[$0] != nil || $0 == .live }, id: \.self) { kind in
                        BrowseView(kind: kind)
                            .tabItem { Label(kind.title, systemImage: kind.symbol) }
                    }
                    FollowingTab()
                        .tabItem { Label("Following", systemImage: "binoculars") }
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .task { await store.loadOnLaunch() }
        .onReceive(store.$playlist) { epg.load(for: store.active, playlist: $0) }
        .alert(
            listEditor.request?.isRename == true ? "Rename List" : "New List",
            isPresented: Binding(get: { listEditor.request != nil }, set: { if !$0 { listEditor.request = nil } }),
            presenting: listEditor.request
        ) { request in
            TextField("Name", text: $listName)
            Button("Cancel", role: .cancel) {}
            Button(request.isRename ? "Rename" : "Create") {
                switch request {
                case .new(let key): store.createList(named: listName, adding: key.map { [$0] } ?? [])
                case .rename(let list): store.renameList(list.id, to: listName)
                }
            }
        }
        .onChange(of: listEditor.request?.id) {
            if case .rename(let list) = listEditor.request { listName = list.name } else { listName = "" }
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

    var symbol: String {
        switch self {
        case .live: "tv"
        case .movie: "film"
        case .series: "play.rectangle.on.rectangle"
        }
    }
}

/// Requests for the list-name prompt, raised from menus anywhere in the app.
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

        var isRename: Bool {
            if case .rename = self { true } else { false }
        }
    }

    @Published var request: Request?
}

/// Menu entries for putting a channel, film, episode or show in Favourites or a list.
struct MembershipMenu: View {
    let key: String
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var listEditor: ListEditor

    var body: some View {
        Button {
            store.toggleFavourite(key: key)
        } label: {
            Label(
                store.favourites.contains(key) ? "Remove from Favourites" : "Add to Favourites",
                systemImage: store.favourites.contains(key) ? "star.slash" : "star"
            )
        }
        Menu {
            ForEach(store.lists) { list in
                Button {
                    store.toggle(key, inList: list.id)
                } label: {
                    if list.contains(key) {
                        Label(list.name, systemImage: "checkmark")
                    } else {
                        Text(list.name)
                    }
                }
            }
            Button {
                listEditor.request = .new(adding: key)
            } label: {
                Label("New List…", systemImage: "plus")
            }
        } label: {
            Label("Add to List", systemImage: "list.bullet")
        }
    }
}

/// Shown in place of a list while the first copy of a playlist downloads.
struct PlaylistLoadingView: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        if store.isLoading {
            ProgressView("Loading playlist…\n\(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                .multilineTextAlignment(.center)
        } else if let error = store.errorMessage {
            ContentUnavailableView("Couldn't load the playlist", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "tv")
        }
    }
}
