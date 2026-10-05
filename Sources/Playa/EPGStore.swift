import Foundation
import PlayaCore

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
    /// The archive days the loaded guide was read with; a change means reading it again.
    private var loadedArchiveDays: [String: Int] = [:]
    private var loadedAt = Date.distantPast
    private var loadTask: Task<Void, Never>?

    /// - Parameter archiveDays: days of archive by lowercased guide id; programmes of those channels
    ///   are kept that far back, so they can be watched from the archive.
    func load(for saved: SavedPlaylist?, playlist: Playlist, archiveDays: [String: Int] = [:]) {
        guard let saved else {
            reset(to: .unavailable)
            return
        }
        if saved.id == loadedPlaylistID, archiveDays == loadedArchiveDays,
           status == .loading || Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return
        }
        loadedArchiveDays = archiveDays
        let now = Date()
        let keepPast = archiveDays.mapValues { now.addingTimeInterval(-Double($0) * 86_400) }
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
                var isStale = false
                if modified.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true {
                    do {
                        let (downloaded, response) = try await URLSession.shared.download(from: url)
                        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            throw URLError(.badServerResponse, userInfo: [
                                NSLocalizedDescriptionKey: "The server answered with HTTP \(http.statusCode)."
                            ])
                        }
                        try? FileManager.default.removeItem(at: cacheFile)
                        try FileManager.default.moveItem(at: downloaded, to: cacheFile)
                    } catch {
                        // A guide covers several days, so the last one fetched is still worth
                        // showing when the server can't be reached for a new one.
                        guard modified != nil, !Task.isCancelled else { throw error }
                        isStale = true
                    }
                }
                let parsed = await Task.detached(priority: .utility) { () -> Guide in
                    guard let stream = InputStream(url: cacheFile) else { return Guide() }
                    return XMLTVParser.parse(
                        stream: stream,
                        wantedChannels: wanted,
                        keepEndingAfter: Date().addingTimeInterval(-3600),
                        keepPast: keepPast
                    )
                }.value
                guard !Task.isCancelled else { return }
                if parsed.isEmpty {
                    // A broken download shouldn't be kept for the next 12 hours. An old guide that
                    // has merely run out stays, in case the server is still down next time.
                    if !isStale { try? FileManager.default.removeItem(at: cacheFile) }
                    loadedPlaylistID = nil
                    status = .failed("The guide has no programmes for this playlist's channels.")
                    return
                }
                guide = parsed
                version += 1
                // An old guide is good for a quarter of an hour, then the server is asked again.
                loadedAt = isStale ? Date().addingTimeInterval(900 - Self.maxAge) : Date()
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
        return Storage.directory.appendingPathComponent("guide-\(id.uuidString).xml")
    }
}
