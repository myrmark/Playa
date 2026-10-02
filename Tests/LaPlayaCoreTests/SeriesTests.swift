import XCTest
@testable import LaPlayaCore

final class SeriesTests: XCTestCase {
    func testParsesEpisodeNames() {
        XCTAssertEqual(EpisodeName.parse("The Simpsons - S06E15"), .init(show: "The Simpsons", season: 6, episode: 15, title: nil))
        XCTAssertEqual(EpisodeName.parse("Alex S02E01"), .init(show: "Alex", season: 2, episode: 1, title: nil))
        XCTAssertEqual(EpisodeName.parse("Solsidan - S01E03 - Starta eget"), .init(show: "Solsidan", season: 1, episode: 3, title: "Starta eget"))
        XCTAssertEqual(EpisodeName.parse("The Rookie_S02E03_The Bet"), .init(show: "The Rookie", season: 2, episode: 3, title: "The Bet"))
        XCTAssertEqual(EpisodeName.parse("The Office (U_S_)_S09E14_Vandalism"), .init(show: "The Office (U_S_)", season: 9, episode: 14, title: "Vandalism"))
        XCTAssertEqual(EpisodeName.parse("Pretty Little Liars - 1x07 - The Homecoming Hangover"), .init(show: "Pretty Little Liars", season: 1, episode: 7, title: "The Homecoming Hangover"))
        XCTAssertEqual(EpisodeName.parse("Zasněná láska - 01x153 - Návrat"), .init(show: "Zasněná láska", season: 1, episode: 153, title: "Návrat"))
        XCTAssertEqual(EpisodeName.parse("الدريشة - S01E05"), .init(show: "الدريشة", season: 1, episode: 5, title: nil))

        XCTAssertNil(EpisodeName.parse("EP02 - Gripanden"))
        XCTAssertNil(EpisodeName.parse("Top Gear 4x4 Special"))
        XCTAssertNil(EpisodeName.parse("S01E01"))
        XCTAssertNil(EpisodeName.parse("News Flash"))
    }

    func testBuildsShowsAndSeasons() {
        func episode(_ id: Int, _ name: String, group: String = "Nordic", logo: String? = nil) -> Channel {
            Channel(id: id, name: name, url: "http://h/series/u/p/\(id).mkv", group: group, logo: logo, tvgID: nil, kind: .series)
        }
        let channels = [
            episode(0, "Solsidan - S02E01"),
            episode(1, "Solsidan - S01E02 - Två", logo: "http://logo/solsidan.png"),
            episode(2, "solsidan - S01E01"),
            episode(3, "EP01 - Pilot"),
            episode(4, "Alex S02E01"),
            episode(5, "Solsidan - S01E01", group: "Other group"),
            Channel(id: 6, name: "SVT1 - S01E01", url: "http://h/u/p/6", group: "Nordic", logo: nil, tvgID: nil, kind: .live),
        ]
        let shows = SeriesIndex.build(from: channels)

        XCTAssertEqual(shows.map(\.name), ["Alex", "Solsidan", "Solsidan", SeriesIndex.looseShowName])
        XCTAssertEqual(shows.map(\.id), [0, 1, 2, 3])

        let solsidan = shows.first { $0.name == "Solsidan" && $0.group == "Nordic" }!
        XCTAssertEqual(solsidan.episodeCount, 3)
        XCTAssertEqual(solsidan.logo, "http://logo/solsidan.png")
        XCTAssertEqual(solsidan.seasons.map(\.number), [1, 2])
        XCTAssertEqual(solsidan.seasons[0].episodes.map(\.channelID), [2, 1])
        XCTAssertEqual(solsidan.seasons[0].episodes.map(\.label), ["Episode 1", "E02 · Två"])
        XCTAssertEqual(solsidan.favouriteKey, "show:Nordic/Solsidan")

        let loose = shows.last!
        XCTAssertEqual(loose.seasons.map(\.label), ["Episodes"])
        XCTAssertEqual(loose.seasons[0].episodes.map(\.label), ["EP01 - Pilot"])
    }
}
