import AVFoundation
import PlayaCore
import SwiftUI

@main
struct PlayaTVApp: App {
    @StateObject private var store = PlaylistStore()
    @StateObject private var epg = EPGStore()
    @StateObject private var resume = ResumeStore()
    @StateObject private var player = MPVPlayer()
    @StateObject private var listEditor = ListEditor()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(epg)
                .environmentObject(resume)
                .environmentObject(player)
                .environmentObject(listEditor)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: PlaylistStore
    @EnvironmentObject private var epg: EPGStore
    @EnvironmentObject private var listEditor: ListEditor
    @State private var tab = ChannelKind.live.rawValue

    var body: some View {
        Group {
            if store.saved.isEmpty {
                NavigationStack {
                    AddPlaylistView()
                }
            } else {
                TabView(selection: $tab) {
                    ForEach(ChannelKind.allCases.filter { store.playlist.countByKind[$0] != nil || $0 == .live }, id: \.self) { kind in
                        Group {
                            if kind == .series {
                                SeriesBrowser()
                            } else {
                                ChannelBrowser(kind: kind)
                            }
                        }
                        .tabItem { Text(kind.title) }
                        .tag(kind.rawValue)
                    }
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag("search")
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag("settings")
                }
            }
        }
        .task {
            await store.loadOnLaunch()
            // Launching with --diagnose (from Xcode or devicectl) reports storage and sync state.
            if CommandLine.arguments.contains("--diagnose") {
                for _ in 0..<3 {
                    print("PLAYA-DIAGNOSE\n\(store.diagnostics)")
                    try? await Task.sleep(for: .seconds(45))
                }
            }
        }
        .onReceive(store.$playlist) { epg.load(for: store.active, playlist: $0) }
        .sheet(item: $listEditor.request) { request in
            ListNameSheet(request: request)
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
}

/// Shown in place of a list while the first copy of a playlist downloads.
struct PlaylistLoadingView: View {
    @EnvironmentObject private var store: PlaylistStore

    var body: some View {
        if store.isLoading {
            ProgressView("Loading playlist…\n\(store.downloadedBytes.formatted(.byteCount(style: .file)))")
                .multilineTextAlignment(.center)
        } else if let error = store.errorMessage {
            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            Text("Nothing here yet.")
                .foregroundStyle(.secondary)
        }
    }
}
