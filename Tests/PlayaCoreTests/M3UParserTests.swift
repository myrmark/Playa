import XCTest
@testable import PlayaCore

final class M3UParserTests: XCTestCase {
    func testParsesAttributesGroupsAndEPG() {
        let text = """
        #EXTM3U url-tvg="http://example.com/epg.xml"
        #EXTINF:-1 tvg-id="svt1.se" tvg-name="SVT1" tvg-logo="http://logo/svt1.png" group-title="Sweden",SVT 1 HD
        http://example.com/live/1.ts
        #EXTINF:-1 tvg-id="" group-title="News, World",BBC News, UK
        http://example.com/live/2.m3u8
        #EXTINF:-1,Plain channel
        #EXTVLCOPT:http-user-agent=Foo
        http://example.com/live/3.ts
        """
        let playlist = M3UParser.parse(text)

        XCTAssertEqual(playlist.epgURL, "http://example.com/epg.xml")
        XCTAssertEqual(playlist.channels.count, 3)
        XCTAssertEqual(playlist.groups, ["Sweden", "News, World", M3UParser.ungrouped])

        let first = playlist.channels[0]
        XCTAssertEqual(first.name, "SVT 1 HD")
        XCTAssertEqual(first.url, "http://example.com/live/1.ts")
        XCTAssertEqual(first.logo, "http://logo/svt1.png")
        XCTAssertEqual(first.tvgID, "svt1.se")

        let second = playlist.channels[1]
        XCTAssertEqual(second.name, "BBC News, UK")
        XCTAssertEqual(second.group, "News, World")
        XCTAssertNil(second.tvgID)

        XCTAssertEqual(playlist.channels[2].name, "Plain channel")
        XCTAssertEqual(playlist.channels[2].url, "http://example.com/live/3.ts")
    }

    func testSplitsLiveMoviesAndSeries() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="svt1.se" group-title="Sweden",SVT 1
        http://host:80/user/pass/101
        #EXTINF:-1 group-title="Nordic",Film [2021]
        http://host:80/movie/user/pass/202.mkv
        #EXTINF:-1 group-title="Nordic",Show - S01E01
        http://host:80/series/user/pass/303.mp4
        #EXTINF:-1 group-title="Clips",Loose file
        http://other.example/video/clip.MP4
        """
        let playlist = M3UParser.parse(text)
        XCTAssertEqual(playlist.channels.map(\.kind), [.live, .movie, .series, .movie])
        XCTAssertEqual(playlist.countByKind, [.live: 1, .movie: 2, .series: 1])
        XCTAssertEqual(playlist.groupsByKind[.live], ["Sweden"])
        XCTAssertEqual(playlist.groupsByKind[.movie], ["Nordic", "Clips"])
        XCTAssertEqual(playlist.groupsByKind[.series], ["Nordic"])
    }

    func testHandlesWindowsLineEndingsAndExtGrp() {
        let text = "#EXTM3U\r\n#EXTINF:-1,One\r\n#EXTGRP:Sports\r\nhttp://a/1\r\n"
        let playlist = M3UParser.parse(text)
        XCTAssertEqual(playlist.channels.count, 1)
        XCTAssertEqual(playlist.channels[0].group, "Sports")
        XCTAssertEqual(playlist.channels[0].url, "http://a/1")
    }
}
