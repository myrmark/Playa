import XCTest
@testable import PlayaCore

final class FollowingTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func channel(_ id: Int, _ name: String, _ tvg: String?, group: String = "Sport") -> Channel {
        Channel(id: id, name: name, url: "http://h/u/p/\(id)", group: group, logo: nil, tvgID: tvg)
    }

    func testFindsMergesAndRanksBroadcasts() {
        let now = date("2026-10-02T18:00:00Z")
        let match = Programme(start: date("2026-10-02T18:45:00Z"), stop: date("2026-10-02T20:45:00Z"), title: "Fotboll: Nations League", description: "Sverige–Norge")
        let guide = Guide(programmes: [
            "sport.se": [match],
            "sport.uk": [Programme(start: match.start, stop: match.stop, title: "Fotboll: Nations League", description: "Sweden v Norway")],
            "news": [Programme(start: date("2026-10-02T19:00:00Z"), stop: date("2026-10-02T19:30:00Z"), title: "Sweden Today")],
            "old": [Programme(start: date("2026-10-02T15:00:00Z"), stop: date("2026-10-02T17:00:00Z"), title: "Sweden yesterday")],
            "arsenal": [Programme(start: date("2026-10-03T12:00:00Z"), stop: date("2026-10-03T14:00:00Z"), title: "Arsenal – Chelsea")],
        ])
        var playlist = Playlist()
        playlist.channels = [
            channel(0, "V Sport 1 SE", "sport.se"), channel(1, "Sky Sports EN", "sport.uk"), channel(2, "V Sport 1 FHD SE", "sport.se"),
            channel(3, "News 24", "news"), channel(4, "Old", "old"), channel(5, "Arsenal TV", "arsenal"),
            channel(6, "Hidden UK", "sport.uk", group: "Adult"),
        ]
        let topics = [
            FollowedTopic(name: "Sweden", keywords: ["Sverige", " "]),
            FollowedTopic(name: "Arsenal", isEnabled: false),
        ]

        let plain = Following.broadcasts(topics: topics, guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400, hiddenGroups: ["Adult"])
        XCTAssertEqual(plain.map(\.programme.title), ["Fotboll: Nations League", "Sweden Today"], "soonest first; the past and disabled topics are left out")
        XCTAssertEqual(plain[0].channels.map(\.name), ["V Sport 1 SE", "Sky Sports EN", "V Sport 1 FHD SE"], "one broadcast, every channel showing it")
        XCTAssertEqual(plain[0].topics, ["Sweden"])

        let english = Following.broadcasts(
            topics: topics, guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400,
            favourites: [playlist.channels[2].key], preferences: FollowPreferences(favouritesFirst: true, languageTags: ["en", "SE"])
        )
        XCTAssertEqual(english[0].channels.map(\.name).prefix(3), ["V Sport 1 FHD SE", "Sky Sports EN", "V Sport 1 SE"], "favourite first, then English, then Swedish")

        let both = Following.broadcasts(
            topics: [topics[0], FollowedTopic(name: "Arsenal")], guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400
        )
        XCTAssertEqual(both.last?.topics, ["Arsenal"])
        XCTAssertTrue(Following.broadcasts(topics: [], guide: guide, playlist: playlist, from: now, horizon: 86_400).isEmpty)
    }

    func testLanguageMarkersMustStandAlone() {
        XCTAssertEqual(Following.languageRank(of: channel(0, "SVT1 HD SE", nil), tags: ["EN", "SE"]), 1)
        XCTAssertEqual(Following.languageRank(of: channel(0, "EN| Sky Sports", nil), tags: ["EN", "SE"]), 0)
        XCTAssertEqual(Following.languageRank(of: channel(0, "Sky [ENG]", nil), tags: ["ENG"]), 0)
        XCTAssertNil(Following.languageRank(of: channel(0, "Sweden Sense", nil), tags: ["SE", "EN"]))
        XCTAssertEqual(Following.languageRank(of: channel(0, "Sky Sports", nil, group: "UK"), tags: ["UK"]), 0, "the group counts too")
        XCTAssertNil(Following.languageRank(of: channel(0, "Sky EN", nil), tags: []))
    }

    func testTopicsSurviveEncoding() throws {
        let topic = FollowedTopic(name: "Sweden", keywords: ["Sverige"], isEnabled: false)
        XCTAssertEqual(try JSONDecoder().decode(FollowedTopic.self, from: JSONEncoder().encode(topic)), topic)
        XCTAssertEqual(topic.searchTerms, ["Sweden", "Sverige"])
    }
}
