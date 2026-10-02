import Foundation
import PlayaCore

/// Remembers where films and episodes were stopped, across launches.
@MainActor
final class ResumeStore: ObservableObject {
    /// Bumped when a row's "Resume at…" / "Watched" label may have changed.
    @Published private(set) var version = 0

    private var book = ResumeBook()
    private let defaults = UserDefaults.standard
    private static let key = "resumePositions"

    init() {
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(ResumeBook.self, from: data) {
            book = decoded
        }
    }

    func resumePosition(for channel: Channel) -> Double? {
        channel.kind == .live ? nil : book.resumePosition(for: channel.url)
    }

    /// Row label for a film or episode that has been started.
    func label(for channel: Channel) -> String? {
        guard channel.kind != .live, let entry = book.entry(for: channel.url) else { return nil }
        if entry.isWatched { return "Watched" }
        return "Resume at \(Duration.seconds(entry.position.rounded()).formatted(.time(pattern: .hourMinuteSecond)))"
    }

    /// - Parameter isFinal: playback of this stream is ending, so its row label should catch up.
    func record(_ channel: Channel, position: Double, duration: Double, isFinal: Bool) {
        guard channel.kind != .live, duration > 0 else { return }
        let labelChanged = book.record(url: channel.url, position: position, duration: duration)
        if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: Self.key)
        }
        if labelChanged || isFinal { version += 1 }
    }
}
