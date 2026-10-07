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

final class XtreamPanelTests: XCTestCase {
    func testReadsPanelDetailsAndArchiveList() throws {
        let panel = try XCTUnwrap(XtreamPanel(playlistURL: "http://host:8080/get.php?username=u&password=p&type=m3u_plus&output=ts"))
        XCTAssertEqual(panel.liveStreamsURL?.absoluteString, "http://host:8080/player_api.php?username=u&password=p&action=get_live_streams")
        XCTAssertNil(XtreamPanel(playlistURL: "http://example.com/list.m3u"))

        XCTAssertEqual(XtreamPanel.streamID(fromStreamURL: "http://host:8080/live/u/p/1234.ts"), 1234)
        XCTAssertEqual(XtreamPanel.streamID(fromStreamURL: "http://host:8080/u/p/77"), 77)

        let list = Data(#"[{"stream_id":1,"tv_archive":1,"tv_archive_duration":"3"},{"stream_id":"2","tv_archive":"1","tv_archive_duration":0},{"stream_id":3,"tv_archive":0}]"#.utf8)
        XCTAssertEqual(XtreamPanel.archiveDays(fromLiveStreams: list), [1: 3, 2: 1])
        XCTAssertEqual(XtreamPanel.timeZone(fromServerInfo: Data(#"{"server_info":{"timezone":"Europe/Stockholm"}}"#.utf8)), "Europe/Stockholm")
    }

    func testArchiveUsesTheServerTimeZone() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000) // 14:13 UTC, 16:13 in Stockholm
        let catchUp = CatchUp(style: "xc", days: 1, source: nil, timeZone: "Europe/Stockholm")
        let channel = Channel(id: 5, name: "Sport", url: "http://host/live/u/p/9.ts", group: "S", logo: nil, tvgID: "s")
        let recording = try XCTUnwrap(channel.archived(
            Programme(start: start, stop: start.addingTimeInterval(3600), title: "Match"), catchUp: catchUp, now: start.addingTimeInterval(600)
        ))
        XCTAssertEqual(recording.url, "http://host/timeshift/u/p/60/2026-09-21:16-13/9.ts")
        XCTAssertTrue(recording.isArchive)
        XCTAssertEqual(recording.kind, .movie)
    }

    func testArchiveFromATimePickedByHand() {
        let channel = Channel(id: 1, name: "One", url: "http://host/live/u/p/42.ts", group: "", logo: nil, tvgID: nil, kind: .live)
        let catchUp = CatchUp(style: "xc", days: 2, source: nil, timeZone: "Europe/Stockholm")
        let now = ISO8601DateFormatter().date(from: "2026-10-07T10:00:00Z")!
        let start = ISO8601DateFormatter().date(from: "2026-10-06T18:00:00Z")!

        let recording = channel.archived(from: start, minutes: 120, catchUp: catchUp, now: now)
        XCTAssertEqual(recording?.url, "http://host/timeshift/u/p/120/2026-10-06:20-00/42.ts")
        XCTAssertEqual(recording?.isArchive, true)
        // Not yet been, and further back than the archive reaches.
        XCTAssertNil(channel.archived(from: now.addingTimeInterval(60), minutes: 30, catchUp: catchUp, now: now))
        XCTAssertNil(channel.archived(from: now.addingTimeInterval(-3 * 86_400), minutes: 30, catchUp: catchUp, now: now))
    }
}
