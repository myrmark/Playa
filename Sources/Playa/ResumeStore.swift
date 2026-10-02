import Combine
import Foundation
import PlayaCore

/// Remembers where films and episodes were stopped, across launches and devices.
@MainActor
final class ResumeStore: ObservableObject {
    /// Bumped when a row's "Resume at…" / "Watched" label may have changed.
    @Published private(set) var version = 0

    private var book = ResumeBook()
    private let defaults = UserDefaults.standard
    private var subscription: AnyCancellable?
    private static let key = "resumePositions"
    private static let syncKey = "resume"
    /// iCloud key-value storage is small; the most recent entries are the ones worth syncing.
    private static let syncedEntries = 400

    init() {
        if let stored = defaults.data(forKey: Self.key) {
            let opened = Vault.open(stored)
            if let decoded = try? JSONDecoder().decode(ResumeBook.self, from: opened ?? stored) {
                // Older versions keyed entries by stream address and stored them unencrypted.
                let needsRekey = decoded.entries.keys.contains { $0.contains("://") }
                book = needsRekey ? decoded.rekeyed { $0.contains("://") ? Channel.key(forStreamURL: $0) : $0 } : decoded
                if opened == nil || needsRekey { save() }
            }
        }
        pull()
        subscription = CloudSync.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    func resumePosition(for channel: Channel) -> Double? {
        channel.kind == .live ? nil : book.resumePosition(for: channel.key)
    }

    /// Row label for a film or episode that has been started.
    func label(for channel: Channel) -> String? {
        guard channel.kind != .live, let entry = book.entry(for: channel.key) else { return nil }
        if entry.isWatched { return "Watched" }
        return "Resume at \(Duration.seconds(entry.position.rounded()).formatted(.time(pattern: .hourMinuteSecond)))"
    }

    /// - Parameter isFinal: playback of this stream is ending, so its row label should catch up
    ///   and other devices should hear about it.
    func record(_ channel: Channel, position: Double, duration: Double, isFinal: Bool) {
        guard channel.kind != .live, duration > 0 else { return }
        let labelChanged = book.record(key: channel.key, position: position, duration: duration)
        save()
        if isFinal { push() }
        if labelChanged || isFinal { version += 1 }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(book), let sealed = Vault.seal(data) {
            defaults.set(sealed, forKey: Self.key)
        }
    }

    private func pull() {
        let remote = CloudSync.read(ResumeBook.self, key: Self.syncKey)
        if let remote, book.merge(remote) {
            save()
            version += 1
        }
        // Anything this device knows that iCloud doesn't yet.
        if !book.entries.isEmpty, book.newest(Self.syncedEntries) != remote { push() }
    }

    private func push() {
        CloudSync.write(book.newest(Self.syncedEntries), key: Self.syncKey)
    }
}
