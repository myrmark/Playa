import Foundation
import LaPlayaCore

/// Downloads and holds the programme guide for the active playlist.
@MainActor
final class EPGStore: ObservableObject {
    enum Status: Equatable {
        case unavailable
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var guide = Guide()
    @Published private(set) var status = Status.unavailable
    /// Bumped whenever `guide` changes.
    @Published private(set) var version = 0

    private static let maxAge: TimeInterval = 12 * 3600
    private var loadedPlaylistID: UUID?
    private var loadedAt = Date.distantPast
    private var loadTask: Task<Void, Never>?

    func load(for saved: SavedPlaylist?, playlist: Playlist) {
        guard let saved else {
            reset(to: .unavailable)
            return
        }
        if saved.id == loadedPlaylistID, status == .loading || Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return
        }
        loadTask?.cancel()
        let wanted = Set(playlist.channels.compactMap { $0.tvgID?.lowercased() })
        guard !wanted.isEmpty, let url = EPGLocator.guideURL(playlistURL: saved.url, advertised: playlist.epgURL) else {
            reset(to: .unavailable)
            return
        }
        reset(to: .loading)
        loadedPlaylistID = saved.id
        let cacheFile = Self.cacheFile(for: saved.id)

        loadTask = Task {
            do {
                let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if modified.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true {
                    let (downloaded, response) = try await URLSession.shared.download(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [
                            NSLocalizedDescriptionKey: "The server answered with HTTP \(http.statusCode)."
                        ])
                    }
                    try? FileManager.default.removeItem(at: cacheFile)
                    try FileManager.default.moveItem(at: downloaded, to: cacheFile)
                }
                let parsed = await Task.detached(priority: .utility) { () -> Guide in
                    guard let stream = InputStream(url: cacheFile) else { return Guide() }
                    return XMLTVParser.parse(
                        stream: stream,
                        wantedChannels: wanted,
                        keepEndingAfter: Date().addingTimeInterval(-3600)
                    )
                }.value
                guard !Task.isCancelled else { return }
                if parsed.isEmpty {
                    // A stale or broken download shouldn't be kept for the next 12 hours.
                    try? FileManager.default.removeItem(at: cacheFile)
                    loadedPlaylistID = nil
                    status = .failed("The guide has no programmes for this playlist's channels.")
                    return
                }
                guide = parsed
                version += 1
                loadedAt = Date()
                status = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadedPlaylistID = nil
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func reset(to status: Status) {
        loadTask?.cancel()
        loadedPlaylistID = nil
        if !guide.isEmpty {
            guide = Guide()
            version += 1
        }
        self.status = status
    }

    private static func cacheFile(for id: UUID) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaPlaya", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("guide-\(id.uuidString).xml")
    }
}
