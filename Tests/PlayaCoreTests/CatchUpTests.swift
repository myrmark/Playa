import XCTest
@testable import PlayaCore

final class CatchUpTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC

    func testReadsArchiveAttributesAndSkipsChannelsWithout() throws {
        let playlist = M3UParser.parse("""
        #EXTM3U catchup-days="2"
        #EXTINF:-1 tvg-id="a" catchup="xc" catchup-days="7",Sport 1
        http://host:8080/live/user/pass/101.ts
        #EXTINF:-1 tvg-id="b",News
        http://host:8080/live/user/pass/102.ts
        #EXTINF:-1 catchup="default" catchup-source="http://archive/{utc}/{duration}.ts",Film channel
        http://host:8080/live/user/pass/103.ts
        #EXTINF:-1 catchup-days="7",A film
        http://host:8080/movie/user/pass/9.mkv
        """)
        XCTAssertEqual(playlist.channels[0].catchUp, CatchUp(style: "xc", days: 7, source: nil))
        // Playlist-wide days apply to channels that give none of their own.
        XCTAssertEqual(playlist.channels[1].catchUp, CatchUp(style: "xc", days: 2, source: nil))
        XCTAssertEqual(playlist.channels[2].catchUp?.source, "http://archive/{utc}/{duration}.ts")
        XCTAssertNil(playlist.channels[3].catchUp, "only live channels have an archive")

        let restored = try XCTUnwrap(PlaylistSnapshot.decode(PlaylistSnapshot.encode(playlist)))
        XCTAssertEqual(restored.channels.map(\.catchUp), playlist.channels.map(\.catchUp))
    }

    func testBuildsArchiveAddresses() {
        let xc = CatchUp(style: "xc", days: 7, source: nil)
        XCTAssertEqual(
            xc.url(streamURL: "http://host:8080/live/user/pass/101.ts", start: start, duration: 5400),
            "http://host:8080/timeshift/user/pass/90/2026-09-21:14-13/101.ts"
        )
        XCTAssertEqual(
            xc.url(streamURL: "http://host:8080/user/pass/101", start: start, duration: 30),
            "http://host:8080/timeshift/user/pass/1/2026-09-21:14-13/101.ts"
        )
        let template = CatchUp(style: "default", days: 3, source: "http://archive/{utc}/{duration}/{Y}-{m}-{d}.ts")
        XCTAssertEqual(template.url(streamURL: "http://x/1", start: start, duration: 600), "http://archive/1790000000/600/2026-09-21.ts")
        let append = CatchUp(style: "append", days: 3, source: "?utc={utc}&lutc={lutc}")
        XCTAssertEqual(
            append.url(streamURL: "http://x/1.m3u8", start: start, duration: 600, now: start.addingTimeInterval(60)),
            "http://x/1.m3u8?utc=1790000000&lutc=1790000060"
        )
        let flussonic = CatchUp(style: "flussonic", days: 3, source: nil)
        XCTAssertEqual(flussonic.url(streamURL: "http://fs/ch1/index.m3u8?token=t", start: start, duration: 600), "http://fs/ch1/index-1790000000-600.m3u8?token=t")
    }

    func testCoversOnlyThePast() {
        let catchUp = CatchUp(style: "xc", days: 2, source: nil)
        let now = start.addingTimeInterval(3600)
        XCTAssertTrue(catchUp.covers(start, now: now))
        XCTAssertFalse(catchUp.covers(now.addingTimeInterval(60), now: now))
        XCTAssertFalse(catchUp.covers(now.addingTimeInterval(-3 * 86_400), now: now))
    }
}
