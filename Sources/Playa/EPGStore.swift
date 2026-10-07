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

    /// What the guide is loaded from and for, kept so it can be fetched again.
    private struct Request {
        /// The guide's address, then the same guide on the playlist's alternative servers.
        let urls: [URL]
        let cacheFile: URL
        let wanted: Set<String>
        let archiveDays: [String: Int]
    }
    private var request: Request?
    private var refreshTask: Task<Void, Never>?
    /// How soon the server is asked again when it had no usable guide.
    private static let retryDelay: TimeInterval = 900

    /// - Parameter archiveDays: days of archive by lowercased guide id; programmes of those channels
    ///   are kept that far back, so they can be watched from the archive.
    func load(for saved: SavedPlaylist?, playlist: Playlist, archiveDays: [String: Int] = [:]) {
        guard let saved else {
            reset(to: .unavailable)
            return
        }
        let urls = EPGLocator.guideURLs(playlistURL: saved.url, advertised: playlist.epgURL, alternativeServers: saved.alternativeServers ?? [])
        if saved.id == loadedPlaylistID, archiveDays == loadedArchiveDays, urls == request?.urls,
           status == .loading || Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return
        }
        let wanted = Set(playlist.channels.compactMap { $0.tvgID?.lowercased() })
        guard !wanted.isEmpty, !urls.isEmpty else {
            reset(to: .unavailable)
            return
        }
        reset(to: .loading)
        loadedArchiveDays = archiveDays
        loadedPlaylistID = saved.id
        request = Request(urls: urls, cacheFile: Self.cacheFile(for: saved.id), wanted: wanted, archiveDays: archiveDays)
        start(downloading: false)
    }

    /// Whether there is a guide address to ask, so `refresh` can do something.
    var canRefresh: Bool { request != nil && status != .loading }

    /// Fetches the guide from the server again now. The guide on show stays until the new one is in.
    func refresh() {
        guard canRefresh else { return }
        status = .loading
        start(downloading: true)
    }

    /// - Parameter downloading: fetch a new guide even when the stored one is recent.
    private func start(downloading: Bool) {
        guard let request else { return }
        let (urls, cacheFile, wanted) = (request.urls, request.cacheFile, request.wanted)
        let now = Date()
        let keepPast = request.archiveDays.mapValues { now.addingTimeInterval(-Double($0) * 86_400) }
        loadTask?.cancel()
        refreshTask?.cancel()

        loadTask = Task {
            func parse(_ file: URL) async -> (guide: Guide, report: GuideReport) {
                await Task.detached(priority: .utility) { () -> (guide: Guide, report: GuideReport) in
                    guard let stream = InputStream(url: file) else { return (Guide(), GuideReport()) }
                    return XMLTVParser.read(
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
            if downloading || modified.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true {
                // The new guide replaces the old one only once it has been read and found to
                // cover this playlist: a broken or empty download must not cost the last good one.
                // The servers are asked one at a time, and the first usable guide is kept.
                let incoming = cacheFile.appendingPathExtension("new")
                for url in urls {
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
                        if !fresh.guide.isEmpty {
                            _ = try FileManager.default.replaceItemAt(cacheFile, withItemAt: incoming)
                            apply(fresh.guide, retryingSoon: false)
                            return
                        }
                        try? FileManager.default.removeItem(at: incoming)
                        problem = problem ?? fresh.report.problem
                    } catch {
                        try? FileManager.default.removeItem(at: incoming)
                        guard !Task.isCancelled else { return }
                        problem = problem ?? error.localizedDescription
                    }
                }
                if urls.count > 1, let first = problem {
                    problem = first + " The alternative servers had no usable guide either."
                }
            }

            // The guide on disk: still fresh, or the last good one while the provider's is unusable.
            // A guide covers several days, so an older one is still worth showing.
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                let stored = await parse(cacheFile).guide
                guard !Task.isCancelled else { return }
                if !stored.isEmpty {
                    apply(stored, retryingSoon: problem != nil)
                    return
                }
            }
            // The next load of the playlist asks again too.
            loadedAt = .distantPast
            if !guide.isEmpty {
                guide = Guide()
                version += 1
            }
            status = .failed(problem ?? "The guide has no programmes for this playlist's channels.")
            refreshLater(after: Self.retryDelay)
        }
    }

    /// Keeps the guide up to date by itself while the app is open.
    private func refreshLater(after delay: TimeInterval) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
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
        loadedAt = retryingSoon ? Date().addingTimeInterval(Self.retryDelay - Self.maxAge) : Date()
        status = .loaded
        refreshLater(after: retryingSoon ? Self.retryDelay : Self.maxAge)
    }

    private func reset(to status: Status) {
        loadTask?.cancel()
        refreshTask?.cancel()
        request = nil
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
