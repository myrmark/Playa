import Combine
import CryptoKit
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
    /// `Channel.key`s of starred channels and `SeriesShow.favouriteKey`s of starred shows.
    @Published private(set) var favourites: Set<String> = []
    /// Collections the user put together, in the order they were created.
    @Published private(set) var lists: [ChannelList] = []

    /// What is synced between devices. Stamps decide whose copy is newer.
    private struct SyncedFavourites: Codable {
        var updatedAt: Date
        var keys: [String]
    }

    private struct SyncedLists: Codable {
        var updatedAt: Date
        var lists: [ChannelList]
    }

    private struct SyncedPlaylists: Codable {
        struct Item: Codable {
            var name: String
            var url: String
        }

        var updatedAt: Date
        var playlists: [Item]
    }

    private var subscription: AnyCancellable?

    private let defaults = UserDefaults.standard
    /// Cached playlists older than this are refreshed in the background.
    private static let maxCacheAge: TimeInterval = 24 * 3600
    private static let favouritesKey = "favourites"
    private static let listsKey = "lists"
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
        toggleFavourite(key: channel.key)
    }

    /// Favourites are keyed by `Channel.key` for channels and by `SeriesShow.favouriteKey` for shows.
    func toggleFavourite(key: String) {
        if favourites.remove(key) == nil {
            favourites.insert(key)
        }
        favouritesChanged()
    }

    private func favouritesChanged() {
        persistFavourites()
        favouritesStamp = Date()
        CloudSync.write(SyncedFavourites(updatedAt: favouritesStamp, keys: favourites.sorted()), key: Self.favouritesKey)
    }

    private var favouritesStamp: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "favouritesStamp")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "favouritesStamp") }
    }

    private var listsStamp: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "listsStamp")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "listsStamp") }
    }

    // MARK: Lists

    @discardableResult
    func createList(named name: String, adding keys: [String] = []) -> UUID {
        var list = ChannelList(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        keys.forEach { list.add($0) }
        lists.append(list)
        listsChanged()
        return list.id
    }

    func renameList(_ id: UUID, to name: String) {
        updateList(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        listsChanged()
    }

    func add(_ keys: [String], toList id: UUID) {
        updateList(id) { list in keys.forEach { list.add($0) } }
    }

    func remove(_ keys: [String], fromList id: UUID) {
        updateList(id) { list in keys.forEach { list.remove($0) } }
    }

    func addFavourites(_ keys: [String]) {
        favourites.formUnion(keys)
        favouritesChanged()
    }

    /// Adds `key` to the list, or removes it if it is already there.
    func toggle(_ key: String, inList id: UUID) {
        updateList(id) { $0.contains(key) ? $0.remove(key) : $0.add(key) }
    }

    /// Moves `key` to sit directly before `other` in the list, or to the end when `other` is nil.
    func move(_ key: String, before other: String?, inList id: UUID) {
        updateList(id) { $0.move(key, before: other) }
    }

    private func updateList(_ id: UUID, _ change: (inout ChannelList) -> Void) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        change(&lists[index])
        listsChanged()
    }

    private func listsChanged() {
        persistLists()
        listsStamp = Date()
        CloudSync.write(SyncedLists(updatedAt: listsStamp, lists: lists), key: Self.listsKey)
    }

    private func persistLists() {
        if let data = try? JSONEncoder().encode(lists), let sealed = Vault.seal(data) {
            defaults.set(sealed, forKey: Self.listsKey)
        }
    }

    private func pullLists() {
        guard let remote = CloudSync.read(SyncedLists.self, key: Self.listsKey) else {
            if !lists.isEmpty { listsChanged() }
            return
        }
        if listsStamp.timeIntervalSince1970 == 0 {
            // First contact: keep the lists both sides have.
            let known = Set(lists.map(\.id))
            lists += remote.lists.filter { !known.contains($0.id) }
            if lists == remote.lists {
                persistLists()
                listsStamp = remote.updatedAt
            } else {
                listsChanged()
            }
        } else if remote.updatedAt > listsStamp {
            lists = remote.lists
            persistLists()
            listsStamp = remote.updatedAt
        }
    }

    private var playlistsStamp: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "playlistsStamp")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "playlistsStamp") }
    }

    private func pullFavourites() {
        let remote = CloudSync.read(SyncedFavourites.self, key: Self.favouritesKey)
        let neverSynced = favouritesStamp.timeIntervalSince1970 == 0
        if let remote, neverSynced {
            // First contact: keep what both sides have instead of letting one replace the other.
            favourites.formUnion(remote.keys)
            favouritesStamp = Date()
        } else if let remote, remote.updatedAt > favouritesStamp {
            favourites = Set(remote.keys)
            favouritesStamp = remote.updatedAt
        } else if remote != nil || favourites.isEmpty {
            return
        } else if neverSynced {
            favouritesStamp = Date()
        }
        persistFavourites()
        if Set(remote?.keys ?? []) != favourites {
            CloudSync.write(SyncedFavourites(updatedAt: favouritesStamp, keys: favourites.sorted()), key: Self.favouritesKey)
        }
    }

    /// A few counts for `Playa --diagnose`; nothing that identifies a provider.
    var diagnostics: String {
        let remote = CloudSync.read(SyncedPlaylists.self, key: Self.savedKey)
        return """
        encryption key available: \(Vault.isAvailable)
        playlists on this device: \(saved.count)
        favourites: \(favourites.count)
        lists: \(lists.count)
        playlists in iCloud: \(remote.map { "\($0.playlists.count), last changed \($0.updatedAt.formatted(date: .abbreviated, time: .standard))" } ?? "none readable")
        last started, per iCloud key-value storage: \(CloudSync.lastSeen)
        """
    }

    /// Playlists that make sense on another device: files on this one don't.
    private var syncablePlaylists: [SavedPlaylist] {
        saved.filter { !$0.url.hasPrefix("file:") }
    }

    private func pushPlaylists() {
        playlistsStamp = Date()
        let items = syncablePlaylists.map { SyncedPlaylists.Item(name: $0.name, url: $0.url) }
        CloudSync.write(SyncedPlaylists(updatedAt: playlistsStamp, playlists: items), key: Self.savedKey)
    }

    /// Adopts playlists added or removed on another device. Matching is by address.
    private func pullPlaylists() async {
        guard let remote = CloudSync.read(SyncedPlaylists.self, key: Self.savedKey) else {
            // Nothing in iCloud yet: offer what this device has.
            if !syncablePlaylists.isEmpty { pushPlaylists() }
            return
        }
        let neverSynced = playlistsStamp.timeIntervalSince1970 == 0
        guard neverSynced || remote.updatedAt > playlistsStamp else { return }

        let remoteURLs = Set(remote.playlists.map(\.url))
        if !neverSynced {
            for entry in syncablePlaylists where !remoteURLs.contains(entry.url) {
                await removeLocally(entry.id)
            }
        }
        for item in remote.playlists {
            if let index = saved.firstIndex(where: { $0.url == item.url }) {
                saved[index].name = item.name
            } else {
                saved.append(SavedPlaylist(name: item.name, url: item.url))
            }
        }
        persist()
        if neverSynced, Set(syncablePlaylists.map(\.url)) != remoteURLs {
            // First contact, and this device had playlists iCloud didn't.
            pushPlaylists()
        } else {
            playlistsStamp = remote.updatedAt
        }
        if active == nil, let first = saved.first {
            activeID = first.id
            persist()
            await show(first, forceDownload: false)
        }
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
        if let sealed = defaults.data(forKey: Self.listsKey), let data = Vault.open(sealed),
           let decoded = try? JSONDecoder().decode([ChannelList].self, from: data) {
            lists = decoded
        }
        // Older versions also stored channel favourites as stream addresses.
        if favourites.contains(where: { $0.contains("://") }) {
            favourites = Set(favourites.map { $0.contains("://") ? Channel.key(forStreamURL: $0) : $0 })
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
            try? FileManager.default.moveItem(at: cacheDirectory.appendingPathComponent("playlist.m3u"), to: cacheFiles(for: migrated.id).plainText)
            defaults.removeObject(forKey: "playlistURL")
            defaults.removeObject(forKey: "lastChannelURL")
            persist()
        }
        if active == nil { activeID = saved.first?.id }
    }

    /// Shows the cached copy of the active playlist straight away if there is one, otherwise downloads it.
    func loadOnLaunch() async {
        CloudSync.start()
        CloudSync.removeLegacyKeychainItem()
        pullFavourites()
        pullLists()
        subscription = CloudSync.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pullFavourites()
                self?.pullLists()
                Task { await self?.pullPlaylists() }
            }
        }
        await pullPlaylists()
        // Convert caches left by older versions, including those of playlists that aren't open.
        let stale = saved.filter { $0.id != activeID }.map(cacheFiles(for:))
        Task.detached(priority: .utility) {
            for files in stale where !FileManager.default.fileExists(atPath: files.snapshot.path) {
                _ = Self.loadCached(files)
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
        pushPlaylists()
        return true
    }

    func select(_ id: UUID) async {
        guard id != activeID, let entry = saved.first(where: { $0.id == id }) else { return }
        activeID = id
        persist()
        await show(entry, forceDownload: false)
    }

    func remove(_ id: UUID) async {
        await removeLocally(id)
        pushPlaylists()
    }

    private func removeLocally(_ id: UUID) async {
        saved.removeAll { $0.id == id }
        let files = cacheFiles(for: id)
        for file in [files.snapshot, files.sealedText, files.plainText] {
            try? FileManager.default.removeItem(at: file)
        }
        defaults.removeObject(forKey: files.digestKey)
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
        let files = cacheFiles(for: entry)
        if !forceDownload, let cached = await Task.detached(priority: .userInitiated, operation: { Self.loadCached(files) }).value {
            if activeID == entry.id { playlist = cached }
            let modified = (try? files.snapshot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        let files = cacheFiles(for: entry)
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
            // The cache is a parsed snapshot, so "unchanged" is judged by a digest of the download.
            let digest = await Task.detached { Self.digest(of: data) }.value
            if digest == defaults.string(forKey: files.digestKey), FileManager.default.fileExists(atPath: files.snapshot.path) {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: files.snapshot.path)
                return .unchanged
            }
            let parsed = await Self.parse(data)
            guard !parsed.channels.isEmpty else {
                if !quietly { errorMessage = "“\(entry.name)” was loaded but contains no channels." }
                return .failed
            }
            await Task.detached { Self.writeSnapshot(of: parsed, digest: digest, to: files) }.value
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

    /// Where a playlist's cache lives. Only the snapshot is current; the other two are the
    /// playlist text as older versions cached it, read once and then replaced by a snapshot.
    private struct CacheFiles: Sendable {
        /// The parsed playlist in `PlaylistSnapshot` form, encrypted. Loads about ten times
        /// faster than parsing the text again.
        let snapshot: URL
        let sealedText: URL
        let plainText: URL
        /// Defaults key holding a digest of the downloaded text the snapshot was made from.
        let digestKey: String
    }

    private func cacheFiles(for entry: SavedPlaylist) -> CacheFiles {
        cacheFiles(for: entry.id)
    }

    private func cacheFiles(for id: UUID) -> CacheFiles {
        let base = cacheDirectory.appendingPathComponent("playlist-\(id.uuidString)")
        return CacheFiles(
            snapshot: base.appendingPathExtension("snapshot"),
            sealedText: base.appendingPathExtension("sealed"),
            plainText: base.appendingPathExtension("m3u"),
            digestKey: "playlistDigest.\(id.uuidString)"
        )
    }

    private nonisolated static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func writeSnapshot(of playlist: Playlist, digest: String, to files: CacheFiles) {
        guard let sealed = Vault.seal(PlaylistSnapshot.encode(playlist)),
              (try? sealed.write(to: files.snapshot, options: .atomic)) != nil
        else { return }
        UserDefaults.standard.set(digest, forKey: files.digestKey)
        try? FileManager.default.removeItem(at: files.sealedText)
        try? FileManager.default.removeItem(at: files.plainText)
    }

    /// The cached playlist, or nil if there is none that this version can read.
    private nonisolated static func loadCached(_ files: CacheFiles) -> Playlist? {
        if let sealed = try? Data(contentsOf: files.snapshot), let data = Vault.open(sealed),
           let playlist = PlaylistSnapshot.decode(data) {
            return playlist
        }
        // A cache from an older version: the playlist text, encrypted or (older still) plain.
        let text = (try? Data(contentsOf: files.sealedText)).flatMap(Vault.open) ?? (try? Data(contentsOf: files.plainText))
        guard let text else { return nil }
        let playlist = M3UParser.parse(text)
        guard !playlist.channels.isEmpty else { return nil }
        writeSnapshot(of: playlist, digest: digest(of: text), to: files)
        return playlist
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
