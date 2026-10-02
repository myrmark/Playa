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
