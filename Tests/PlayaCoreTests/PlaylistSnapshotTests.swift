import XCTest
@testable import PlayaCore

final class PlaylistSnapshotTests: XCTestCase {
    private let text = """
    #EXTM3U url-tvg="http://example.com/epg.xml"
    #EXTINF:-1 tvg-id="svt1.se" tvg-logo="http://logo/svt1.png" group-title="Sweden",SVT 1 HD
    http://host:80/user/pass/101
    #EXTINF:-1 group-title="Nordic",Film åäö [2021]
    http://host:80/movie/user/pass/202.mkv
    #EXTINF:-1 group-title="Nordic",Solsidan - S01E01
    http://host:80/series/user/pass/303.mp4
    #EXTINF:-1 group-title="Sweden",No logo
    http://host:80/user/pass/102
    """

    func testRoundTrip() throws {
        let playlist = M3UParser.parse(text)
        let restored = try XCTUnwrap(PlaylistSnapshot.decode(PlaylistSnapshot.encode(playlist)))

        XCTAssertEqual(restored.channels, playlist.channels)
        XCTAssertEqual(restored.groups, playlist.groups)
        XCTAssertEqual(restored.groupsByKind, playlist.groupsByKind)
        XCTAssertEqual(restored.countByKind, playlist.countByKind)
        XCTAssertEqual(restored.epgURL, playlist.epgURL)
        XCTAssertEqual(restored.shows, playlist.shows)
        XCTAssertNil(restored.channels[3].logo)
        XCTAssertNil(restored.channels[3].tvgID)
    }

    func testRejectsOtherData() {
        XCTAssertNil(PlaylistSnapshot.decode(Data()))
        XCTAssertNil(PlaylistSnapshot.decode(Data(text.utf8)))

        var snapshot = PlaylistSnapshot.encode(M3UParser.parse(text))
        XCTAssertNil(PlaylistSnapshot.decode(snapshot.prefix(snapshot.count - 5)), "a truncated file")
        snapshot[4] = 99
        XCTAssertNil(PlaylistSnapshot.decode(snapshot), "another format version")
    }

    func testEmptyPlaylist() throws {
        let restored = try XCTUnwrap(PlaylistSnapshot.decode(PlaylistSnapshot.encode(Playlist())))
        XCTAssertTrue(restored.channels.isEmpty)
        XCTAssertNil(restored.epgURL)
    }
}
