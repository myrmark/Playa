import XCTest
@testable import PlayaCore

final class EPGTests: XCTestCase {
    func testParsesXMLTVDates() {
        XCTAssertEqual(XMLTVParser.date(from: "19700101000000 +0000"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(XMLTVParser.date(from: "20261002183000 +0200"), ISO8601DateFormatter().date(from: "2026-10-02T16:30:00Z"))
        XCTAssertEqual(XMLTVParser.date(from: "20240229233000 -0530"), ISO8601DateFormatter().date(from: "2024-03-01T05:00:00Z"))
        XCTAssertEqual(XMLTVParser.date(from: "20260101120000"), ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        XCTAssertNil(XMLTVParser.date(from: "garbage"))
    }

    func testParsesProgrammesAndFindsNowAndNext() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <tv>
          <channel id="SVT1.se"><display-name>SVT1</display-name></channel>
          <programme start="20261002170000 +0000" stop="20261002180000 +0000" channel="SVT1.se"><title>Old &amp; gone</title></programme>
          <programme start="20261002190000 +0000" stop="20261002200000 +0000" channel="SVT1.se"><title lang="sv">Rapport</title><desc>News</desc></programme>
          <programme start="20261002180000 +0000" stop="20261002190000 +0000" channel="SVT1.se"><title>Sportnytt</title></programme>
          <programme start="20261002180000 +0000" stop="20261002190000 +0000" channel="other.se"><title>Ignored</title></programme>
        </tv>
        """
        let now = ISO8601DateFormatter().date(from: "2026-10-02T18:30:00Z")!
        let guide = XMLTVParser.parse(
            stream: InputStream(data: Data(xml.utf8)),
            wantedChannels: ["svt1.se"],
            keepEndingAfter: now.addingTimeInterval(-600)
        )

        XCTAssertEqual(Array(guide.programmes.keys), ["svt1.se"])
        XCTAssertEqual(guide.programmes["svt1.se"]?.map(\.title), ["Sportnytt", "Rapport"])

        let current = guide.nowAndNext(channelID: "SVT1.se", at: now)
        XCTAssertEqual(current.now?.title, "Sportnytt")
        XCTAssertEqual(current.next?.title, "Rapport")
        XCTAssertEqual(current.next?.description, "News")
        XCTAssertNil(current.now?.description)

        let gap = guide.nowAndNext(channelID: "svt1.se", at: now.addingTimeInterval(-3600))
        XCTAssertNil(gap.now)
        XCTAssertEqual(gap.next?.title, "Sportnytt")

        let window = guide.programmes(channelID: "SVT1.se", from: now, to: now.addingTimeInterval(1800))
        XCTAssertEqual(window.map(\.title), ["Sportnytt"])
        let wide = guide.programmes(channelID: "svt1.se", from: now, to: now.addingTimeInterval(3600))
        XCTAssertEqual(wide.map(\.title), ["Sportnytt", "Rapport"])
        XCTAssertTrue(guide.programmes(channelID: "svt1.se", from: now.addingTimeInterval(86_400), to: now.addingTimeInterval(90_000)).isEmpty)

        let after = guide.nowAndNext(channelID: "svt1.se", at: now.addingTimeInterval(86_400))
        XCTAssertNil(after.now)
        XCTAssertNil(after.next)
        XCTAssertNil(guide.nowAndNext(channelID: nil, at: now).now)
    }

    func testSearchesProgrammes() {
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        let now = date("2026-10-02T18:30:00Z")
        let guide = Guide(programmes: [
            "sport1": [
                Programme(start: date("2026-10-02T18:00:00Z"), stop: date("2026-10-02T19:00:00Z"), title: "Studio"),
                Programme(start: date("2026-10-02T19:00:00Z"), stop: date("2026-10-02T21:00:00Z"), title: "Fotboll", description: "Nations League: Sverige–Norge"),
            ],
            "sport2": [
                Programme(start: date("2026-10-02T18:00:00Z"), stop: date("2026-10-02T20:00:00Z"), title: "UEFA Nations League"),
            ],
            "news": [
                Programme(start: date("2026-10-02T17:00:00Z"), stop: date("2026-10-02T18:00:00Z"), title: "Nations League igår"),
                Programme(start: date("2026-10-05T18:00:00Z"), stop: date("2026-10-05T19:00:00Z"), title: "Nations League senare"),
            ],
        ])
        let hits = guide.search("nations league", from: now, horizon: 36 * 3600)
        XCTAssertEqual(hits["sport1"]?.title, "Fotboll", "matched through its description")
        XCTAssertEqual(hits["sport2"]?.title, "UEFA Nations League")
        XCTAssertNil(hits["news"], "one is over and the other is beyond the horizon")

        func channel(_ id: Int, _ name: String, _ tvg: String?, group: String = "Sport", kind: ChannelKind = .live) -> Channel {
            Channel(id: id, name: name, url: "http://h/u/p/\(id)", group: group, logo: nil, tvgID: tvg, kind: kind)
        }
        var playlist = Playlist()
        playlist.channels = [
            channel(0, "Sport 1 HD", "SPORT1"), channel(1, "Sport 2 HD", "sport2"), channel(2, "Sport 2 FHD", "sport2"),
            channel(3, "No guide", nil), channel(4, "Hidden", "sport2", group: "Adult"), channel(5, "A film", "sport2", kind: .movie),
        ]
        let found = guide.channels(showing: "Nations League", in: playlist, from: now, hiddenGroups: ["Adult"])
        XCTAssertEqual(found.map(\.channel.name), ["Sport 2 HD", "Sport 2 FHD", "Sport 1 HD"], "on now first, then later")

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertTrue(found[0].programme.searchLabel(at: now, calendar: utc).hasPrefix("Now · "))
        XCTAssertTrue(found[2].programme.searchLabel(at: now, calendar: utc).hasSuffix(" · Fotboll"))
        XCTAssertFalse(found[2].programme.searchLabel(at: now, calendar: utc).hasPrefix("Now"))
    }

    func testLocatesGuideURL() {
        XCTAssertEqual(
            EPGLocator.guideURL(playlistURL: "http://host:8080/get.php?username=u&password=p&type=m3u_plus&output=ts", advertised: nil)?.absoluteString,
            "http://host:8080/xmltv.php?username=u&password=p"
        )
        XCTAssertEqual(
            EPGLocator.guideURL(playlistURL: "http://host/get.php?username=u&password=p", advertised: "http://epg.example/guide.xml")?.absoluteString,
            "http://epg.example/guide.xml"
        )
        XCTAssertNil(EPGLocator.guideURL(playlistURL: "file:///Users/me/tv/sport.m3u", advertised: nil))
    }
}
