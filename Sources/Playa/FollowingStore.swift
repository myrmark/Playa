import Combine
import Foundation
import PlayaCore

/// The teams, sports and shows the user follows, and the broadcasts of them found in the guide.
@MainActor
final class FollowingStore: ObservableObject {
    @Published private(set) var topics: [FollowedTopic] = []
    @Published private(set) var preferences = FollowPreferences()
    @Published private(set) var broadcasts: [Broadcast] = []
    @Published private(set) var isSearching = false

    /// What is synced between devices.
    private struct Synced: Codable {
        var updatedAt: Date
        var topics: [FollowedTopic]
        var preferences: FollowPreferences
    }

    /// How far ahead to look. Guides rarely reach further than this.
    nonisolated static let horizon: TimeInterval = 7 * 86_400

    private let defaults = UserDefaults.standard
    private static let key = "following"
    private var subscription: AnyCancellable?
    private var searchTask: Task<Void, Never>?

    private var stamp: Date {
        get { Date(timeIntervalSince1970: defaults.double(forKey: "followingStamp")) }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: "followingStamp") }
    }

    init() {
        if let data = defaults.data(forKey: Self.key), let stored = try? JSONDecoder().decode(Synced.self, from: data) {
            topics = stored.topics
            preferences = stored.preferences
        }
        pull()
        subscription = CloudSync.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    func add(name: String, keywords: [String]) {
        topics.append(FollowedTopic(name: name.trimmingCharacters(in: .whitespaces), keywords: keywords))
        changed()
    }

    func update(_ id: UUID, name: String, keywords: [String]) {
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return }
        topics[index].name = name.trimmingCharacters(in: .whitespaces)
        topics[index].keywords = keywords
        changed()
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return }
        topics[index].isEnabled = isEnabled
        changed()
    }

    func delete(_ id: UUID) {
        topics.removeAll { $0.id == id }
        changed()
    }

    func setFavouritesFirst(_ value: Bool) {
        preferences.favouritesFirst = value
        changed()
    }

    /// Takes the tags as the user typed them: "SE, EN" or "se en".
    func setLanguageTags(_ text: String) {
        let tags = Self.keywords(from: text).map { $0.uppercased() }
        guard tags != preferences.languageTags else { return }
        preferences.languageTags = tags
        changed()
    }

    /// Splits "Sverige, SWE" into its keywords.
    static func keywords(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func changed() {
        stamp = Date()
        let synced = Synced(updatedAt: stamp, topics: topics, preferences: preferences)
        if let data = try? JSONEncoder().encode(synced) { defaults.set(data, forKey: Self.key) }
        CloudSync.write(synced, key: Self.key)
    }

    private func pull() {
        guard let remote = CloudSync.read(Synced.self, key: Self.key) else {
            if !topics.isEmpty { CloudSync.write(Synced(updatedAt: stamp, topics: topics, preferences: preferences), key: Self.key) }
            return
        }
        guard remote.updatedAt > stamp else { return }
        topics = remote.topics
        preferences = remote.preferences
        stamp = remote.updatedAt
        if let data = try? JSONEncoder().encode(remote) { defaults.set(data, forKey: Self.key) }
    }

    /// Looks through the guide again. Call when the topics, the guide or the favourites change.
    func search(guide: Guide, playlist: Playlist, favourites: Set<String>, hiddenGroups: Set<String>) {
        searchTask?.cancel()
        let topics = topics, preferences = preferences
        // Hidden groups are stored per section; only the live ones matter to the guide.
        let hiddenLive = Set(hiddenGroups.compactMap { $0.hasPrefix("live/") ? String($0.dropFirst(5)) : nil })
        isSearching = true
        searchTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Following.broadcasts(
                    topics: topics, guide: guide, playlist: playlist, from: Date(), horizon: Self.horizon,
                    favourites: favourites, preferences: preferences, hiddenGroups: hiddenLive
                )
            }.value
            if Task.isCancelled { return }
            broadcasts = found
            isSearching = false
        }
    }
}

extension Broadcast {
    /// Broadcasts grouped by the day they start, in order, for sectioned lists.
    static func byDay(_ broadcasts: [Broadcast], calendar: Calendar = .current) -> [(day: Date, broadcasts: [Broadcast])] {
        var days: [(day: Date, broadcasts: [Broadcast])] = []
        for broadcast in broadcasts {
            let day = calendar.startOfDay(for: broadcast.programme.start)
            if days.last?.day == day {
                days[days.count - 1].broadcasts.append(broadcast)
            } else {
                days.append((day, [broadcast]))
            }
        }
        return days
    }

    /// "Today", "Tomorrow" or the weekday and date.
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var timeRange: String {
        "\(programme.start.formatted(date: .omitted, time: .shortened))–\(programme.stop.formatted(date: .omitted, time: .shortened))"
    }

    func isOnNow(at date: Date) -> Bool {
        programme.start <= date && date < programme.stop
    }
}
