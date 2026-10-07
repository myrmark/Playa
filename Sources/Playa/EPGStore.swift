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
            func parse(_ file: URL) async -> Guide {
                await Task.detached(priority: .utility) { () -> Guide in
                    guard let stream = InputStream(url: file) else { return Guide() }
                    return XMLTVParser.parse(
                        stream: stream,
                        wantedChannels: wanted,
                        keepEndingAfter: Date().addingTimeInterval(-3600),
                        keepPast: keepPast
                    )
                }.value
            }

            let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            /// Why a new guide couldn't be had, when that was tried and failed.
            var problem: String?
            if modified.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true {
                // The new guide replaces the old one only once it has been read and found to
                // cover this playlist: a broken or empty download must not cost the last good one.
                let incoming = cacheFile.appendingPathExtension("new")
                do {
                    let (downloaded, response) = try await Self.session.download(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse, userInfo: [
                            NSLocalizedDescriptionKey: "The server answered with HTTP \(http.statusCode)."
                        ])
                    }
                    try? FileManager.default.removeItem(at: incoming)
                    try FileManager.default.moveItem(at: downloaded, to: incoming)
                    let fresh = await parse(incoming)
                    guard !Task.isCancelled else { return }
                    if !fresh.isEmpty {
                        _ = try FileManager.default.replaceItemAt(cacheFile, withItemAt: incoming)
                        apply(fresh, retryingSoon: false)
                        return
                    }
                    try? FileManager.default.removeItem(at: incoming)
                    problem = "The guide the provider sent has no programmes for this playlist's channels."
                } catch {
                    try? FileManager.default.removeItem(at: incoming)
                    guard !Task.isCancelled else { return }
                    problem = error.localizedDescription
                }
            }

            // The guide on disk: still fresh, or the last good one while the provider's is unusable.
            // A guide covers several days, so an older one is still worth showing.
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                let stored = await parse(cacheFile)
                guard !Task.isCancelled else { return }
                if !stored.isEmpty {
                    apply(stored, retryingSoon: problem != nil)
                    return
                }
            }
            loadedPlaylistID = nil
            status = .failed(problem ?? "The guide has no programmes for this playlist's channels.")
        }
    }

    /// A slow or stalled guide server gives up after ten minutes instead of hanging on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    private func apply(_ parsed: Guide, retryingSoon: Bool) {
        guide = parsed
        version += 1
        // An old guide kept because the new one failed is good for a quarter of an hour, then
        // the server is asked again.
        loadedAt = retryingSoon ? Date().addingTimeInterval(900 - Self.maxAge) : Date()
        status = .loaded
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
