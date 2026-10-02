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

        // Limited to a list of sports channels, the news programme that merely mentions Sweden is gone.
        let sports = ChannelList(name: "Sports", keys: [playlist.channels[1].key, playlist.channels[2].key])
        let inList = Following.broadcasts(
            topics: [FollowedTopic(name: "Sweden", keywords: ["Sverige"], scope: .list(sports.id))],
            guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400, lists: [sports]
        )
        XCTAssertEqual(inList.map(\.programme.title), ["Fotboll: Nations League"])
        XCTAssertEqual(Set(inList[0].channels.map(\.name)), ["Sky Sports EN", "V Sport 1 FHD SE"], "only the channels in the list")

        let inFavourites = Following.broadcasts(
            topics: [FollowedTopic(name: "Sweden", scope: .favourites)],
            guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400, favourites: [playlist.channels[3].key]
        )
        XCTAssertEqual(inFavourites.map(\.programme.title), ["Sweden Today"])

        let missingList = Following.broadcasts(
            topics: [FollowedTopic(name: "Sweden", scope: .list(UUID()))],
            guide: guide, playlist: playlist, from: now, horizon: 7 * 86_400
        )
        XCTAssertEqual(missingList.count, 2, "a deleted list means no limit")
    }

    func testQuotedTermsMatchWholeWordsOnly() {
        let loose = SearchTerm("swe")
        XCTAssertFalse(loose.wholeWord)
        XCTAssertTrue(loose.matches("Sweet dreams"))
        XCTAssertTrue(loose.matches("The answers"))

        let whole = SearchTerm("\"SWE\"")
        XCTAssertEqual(whole.text, "SWE")
        XCTAssertTrue(whole.wholeWord)
        XCTAssertTrue(whole.matches("Fotboll: SWE–NOR"))
        XCTAssertTrue(whole.matches("swe"))
        XCTAssertTrue(whole.matches("Final (SWE)"))
        XCTAssertTrue(whole.matches("Sweet answers, then SWE v NOR"), "a later whole-word occurrence still counts")
        XCTAssertFalse(whole.matches("Sweet dreams"))
        XCTAssertFalse(whole.matches("The answers"))
        XCTAssertFalse(whole.matches("SWE2"))

        XCTAssertTrue(SearchTerm("“Nations League”").wholeWord, "typographic quotes work too")
        XCTAssertTrue(SearchTerm("“Nations League”").matches("UEFA Nations League: final"))
        XCTAssertFalse(SearchTerm("\"\"").matches("anything"))

        let now = date("2026-10-02T18:00:00Z")
        let guide = Guide(programmes: [
            "a": [Programme(start: date("2026-10-02T19:00:00Z"), stop: date("2026-10-02T20:00:00Z"), title: "Sweet Home")],
            "b": [Programme(start: date("2026-10-02T19:00:00Z"), stop: date("2026-10-02T20:00:00Z"), title: "Ishockey", description: "SWE–FIN")],
        ])
        var playlist = Playlist()
        playlist.channels = [channel(0, "A", "a"), channel(1, "B", "b")]
        let found = Following.broadcasts(
            topics: [FollowedTopic(name: "Sverige", keywords: ["\"SWE\""])], guide: guide, playlist: playlist, from: now, horizon: 86_400
        )
        XCTAssertEqual(found.map(\.programme.title), ["Ishockey"])
        XCTAssertEqual(guide.search("\"swe\"", from: now, horizon: 86_400).keys.sorted(), ["b"], "the guide search understands quotes too")
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
        let topic = FollowedTopic(name: "Sweden", keywords: ["Sverige"], isEnabled: false, scope: .list(UUID()))
        XCTAssertEqual(try JSONDecoder().decode(FollowedTopic.self, from: JSONEncoder().encode(topic)), topic)
        // Topics saved before scopes existed still load.
        let old = Data(#"{"id":"11111111-2222-3333-4444-555555555555","name":"Sweden","keywords":[],"isEnabled":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FollowedTopic.self, from: old).scope)
        XCTAssertEqual(topic.searchTerms, ["Sweden", "Sverige"])
    }
}
