import Foundation
import PlayaCore

struct SavedPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var lastChannelURL: String?
}

@MainActor
final class PlaylistStore: ObservableObject {
    /// Every playlist the user has added.
    @Published private(set) var saved: [SavedPlaylist] = []
    @Published private(set) var activeID: UUID?
    /// Parsed contents of the active playlist.
    @Published private(set) var playlist = Playlist()
    /// True while a playlist is being downloaded, whether or not a cached copy is already on screen.
    @Published private(set) var isLoading = false
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published var errorMessage: String?
    /// Stream URLs of starred channels, shared by all playlists.
    @Published private(set) var favourites: Set<String> = []

    private let defaults = UserDefaults.standard
    /// Cached playlists older than this are refreshed in the background.
    private static let maxCacheAge: TimeInterval = 24 * 3600
    private static let favouritesKey = "favourites"
    private static let savedKey = "playlists"
    private static let activeKey = "activePlaylistID"

    var active: SavedPlaylist? {
        saved.first { $0.id == activeID }
    }

    var lastChannelURL: String? {
        get { active?.lastChannelURL }
        set {
            guard let index = saved.firstIndex(where: { $0.id == activeID }) else { return }
            saved[index].lastChannelURL = newValue
            persist()
        }
    }

    func toggleFavourite(_ channel: Channel) {
        toggleFavourite(key: channel.url)
    }

    /// Favourites are keyed by stream URL for channels and by `SeriesShow.favouriteKey` for shows.
    func toggleFavourite(key: String) {
        if favourites.remove(key) == nil {
            favourites.insert(key)
        }
        persistFavourites()
    }

    init() {
        if let sealed = defaults.data(forKey: Self.favouritesKey), let data = Vault.open(sealed),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            favourites = Set(decoded)
        } else if let plain = defaults.stringArray(forKey: Self.favouritesKey) {
            // Versions before the vault stored favourites and playlists unencrypted.
            favourites = Set(plain)
            persistFavourites()
        }
        if let stored = defaults.data(forKey: Self.savedKey),
           let decoded = try? JSONDecoder().decode([SavedPlaylist].self, from: Vault.open(stored) ?? stored) {
            saved = decoded
            activeID = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
            if Vault.open(stored) == nil { persist() }
        } else if let legacyURL = defaults.string(forKey: "playlistURL"), !legacyURL.isEmpty {
            // Versions before multiple playlists stored a single URL.
            let migrated = SavedPlaylist(
                name: Self.defaultName(for: legacyURL),
                url: legacyURL,
                lastChannelURL: defaults.string(forKey: "lastChannelURL")
            )
            saved = [migrated]
            activeID = migrated.id
            try? FileManager.default.moveItem(at: cacheDirectory.appendingPathComponent("playlist.m3u"), to: legacyCacheFile(for: migrated.id))
            defaults.removeObject(forKey: "playlistURL")
            defaults.removeObject(forKey: "lastChannelURL")
            persist()
        }
        if active == nil { activeID = saved.first?.id }
    }

    /// Shows the cached copy of the active playlist straight away if there is one, otherwise downloads it.
    func loadOnLaunch() async {
        // Seal plain-text caches left by older versions, including playlists that aren't open.
        let files = saved.map { (cacheFile(for: $0.id), legacyCacheFile(for: $0.id)) }
        Task.detached(priority: .utility) {
            for (file, legacy) in files where FileManager.default.fileExists(atPath: legacy.path) {
                _ = Self.readCache(file, legacy: legacy)
            }
        }
        guard let active else { return }
        await show(active, forceDownload: false)
    }

    /// Downloads and adds a playlist, then switches to it. Nothing is saved if it can't be loaded.
    func add(name: String, url urlString: String) async -> Bool {
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = saved.first(where: { $0.url == urlString }) {
            errorMessage = "“\(existing.name)” already uses this address."
            return false
        }
        let entry = SavedPlaylist(name: name.isEmpty ? Self.defaultName(for: urlString) : name, url: urlString)
        guard case .updated(let parsed) = await download(entry, quietly: false) else { return false }
        saved.append(entry)
        activeID = entry.id
        playlist = parsed
        persist()
        return true
    }

    func select(_ id: UUID) async {
        guard id != activeID, let entry = saved.first(where: { $0.id == id }) else { return }
        activeID = id
        persist()
        await show(entry, forceDownload: false)
    }

    func remove(_ id: UUID) async {
        saved.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: cacheFile(for: id))
        try? FileManager.default.removeItem(at: legacyCacheFile(for: id))
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("guide-\(id.uuidString).xml"))
        if activeID == id {
            activeID = saved.first?.id
            playlist = Playlist()
            if let active { await show(active, forceDownload: false) }
        }
        persist()
    }

    /// Downloads the active playlist again.
    func refresh() async {
        guard let active else { return }
        await show(active, forceDownload: true)
    }

    private func show(_ entry: SavedPlaylist, forceDownload: Bool) async {
        errorMessage = nil
        let cacheFile = cacheFile(for: entry.id)
        let legacyFile = legacyCacheFile(for: entry.id)
        if !forceDownload, let cached = await Task.detached(operation: { Self.readCache(cacheFile, legacy: legacyFile) }).value {
            let parsed = await Self.parse(cached)
            if activeID == entry.id { playlist = parsed }
            let modified = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if modified.map({ Date().timeIntervalSince($0) > Self.maxCacheAge }) ?? true {
                // The cached copy stays on screen and usable while the new one downloads.
                Task {
                    if case .updated(let fresh) = await download(entry, quietly: true), activeID == entry.id {
                        playlist = fresh
                    }
                }
            }
            return
        }
        let result = await download(entry, quietly: false)
        guard activeID == entry.id else { return }
        if case .updated(let parsed) = result {
            playlist = parsed
        } else if case .failed = result, !forceDownload {
            // Don't leave another playlist's channels on screen under this one's name.
            playlist = Playlist()
        }
    }

    private enum DownloadResult {
        case updated(Playlist)
        /// Identical to the cached copy, so there is nothing to swap in.
        case unchanged
        case failed
    }

    /// Fetches and parses a playlist and updates its cache. A quiet download leaves
    /// `errorMessage` alone: the cached copy is still showing, so a failure isn't worth interrupting for.
    private func download(_ entry: SavedPlaylist, quietly: Bool) async -> DownloadResult {
        guard let url = URL(string: entry.url), url.scheme != nil else {
            if !quietly { errorMessage = "That doesn't look like a valid playlist URL." }
            return .failed
        }
        isLoading = true
        downloadedBytes = 0
        if !quietly { errorMessage = nil }
        defer { isLoading = false }
        let cacheFile = cacheFile(for: entry.id)
        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached { try Data(contentsOf: url) }.value
            } else {
                let progress = DownloadProgress()
                let poll = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(400))
                        downloadedBytes = progress.bytesReceived
                    }
                }
                defer { poll.cancel() }
                let (body, response) = try await URLSession.shared.data(from: url, delegate: progress)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse, userInfo: [
                        NSLocalizedDescriptionKey: "The server answered with HTTP \(http.statusCode)."
                    ])
                }
                data = body
            }
            let isUnchanged = await Task.detached { Self.readCache(cacheFile, legacy: nil) == data }.value
            if isUnchanged {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheFile.path)
                return .unchanged
            }
            let parsed = await Self.parse(data)
            guard !parsed.channels.isEmpty else {
                if !quietly { errorMessage = "“\(entry.name)” was loaded but contains no channels." }
                return .failed
            }
            await Task.detached { try? Vault.seal(data)?.write(to: cacheFile, options: .atomic) }.value
            return .updated(parsed)
        } catch {
            if !quietly { errorMessage = "Could not load “\(entry.name)”: \(error.localizedDescription)" }
            return .failed
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved), let sealed = Vault.seal(data) {
            defaults.set(sealed, forKey: Self.savedKey)
        }
        defaults.set(activeID?.uuidString, forKey: Self.activeKey)
    }

    private var cacheDirectory: URL { Storage.directory }

    private func persistFavourites() {
        if let data = try? JSONEncoder().encode(favourites.sorted()), let sealed = Vault.seal(data) {
            defaults.set(sealed, forKey: Self.favouritesKey)
        }
    }

    /// The cached playlist, decrypted. A plain-text cache left by an older version is
    /// sealed and deleted the first time it is read.
    private nonisolated static func readCache(_ file: URL, legacy: URL?) -> Data? {
        if let sealed = try? Data(contentsOf: file) {
            return Vault.open(sealed)
        }
        guard let legacy, let plain = try? Data(contentsOf: legacy), let sealed = Vault.seal(plain) else { return nil }
        if (try? sealed.write(to: file, options: .atomic)) != nil {
            try? FileManager.default.removeItem(at: legacy)
        }
        return plain
    }

    private func legacyCacheFile(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("playlist-\(id.uuidString).m3u")
    }

    private func cacheFile(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("playlist-\(id.uuidString).sealed")
    }

    private static func defaultName(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "Playlist" }
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        return url.host ?? "Playlist"
    }

    private static func parse(_ data: Data) async -> Playlist {
        await Task.detached(priority: .userInitiated) {
            M3UParser.parse(data)
        }.value
    }
}

/// Lets the store report how much of a playlist has arrived while it downloads.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    var bytesReceived: Int64 {
        lock.withLock { task?.countOfBytesReceived ?? 0 }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }
}
