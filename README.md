<p align="center">
  <img src="Support/AppIcon.png" width="160" alt="Playa icon">
</p>

# Playa

A free, native IPTV player for macOS. Point it at the M3U playlist from your provider and watch live TV, films and series, with a TV guide.

Playa is a player only. It ships with no channels or streams; you bring your own playlist.

> **Status: early.** It works well for daily use on the author's Mac, but it has to be built from source and needs Homebrew's mpv installed. A self-contained download is planned.

## Features

- **Playlists**: add several M3U playlists by URL or from a file and switch between them. Playlists are cached, so the app opens instantly and refreshes in the background.
- **Live TV, Films and Series**: provider playlists that mix all three are split into sections. Series are grouped into shows and seasons.
- **TV guide**: now/next on every channel, plus a full-window schedule grid. The guide is read from the playlist's XMLTV address, or found automatically for Xtream-style `get.php` playlists.
- **Favourites**: star channels, films and shows.
- **Search** across channels, films and shows.
- **Plays almost anything**: playback uses [mpv](https://mpv.io), with hardware decoding.
- **Built for big playlists**: tested with a playlist of about 290,000 entries.

## Requirements

- macOS 14 or later
- Xcode or the Xcode Command Line Tools
- [Homebrew](https://brew.sh)

## Build and run

```sh
brew install mpv pkg-config
git clone <this repository>
cd Playa
./build-app.sh run
```

This builds `Playa.app` in the repository folder and launches it. Run the tests with `swift test`.

## Using it

1. Click **+** in the toolbar and paste your M3U URL, or choose a `.m3u` file.
2. Pick a channel in the sidebar. Use the **Live TV / Films / Series** switch and the group picker to narrow the list.
3. Click the star on a row to add it to your favourites.
4. Press **⌘G** for the TV guide.

| Shortcut | Action |
|---|---|
| Space | Pause / resume |
| ⌘D | Add or remove the current channel as a favourite |
| ⌘G | Show the TV guide |
| Double-click the video | Full screen |

## One stream at a time

Many IPTV providers allow a single stream per subscription and may ban accounts that open a second one. Playa is built not to do that by accident:

- It never starts a stream by itself. On launch the last channel is selected, but nothing plays until you press play.
- When you switch channels, the old stream is closed before the new one is opened, with a short pause in between.
- It does not reconnect a dropped channel automatically; it shows a **Reconnect** button instead.

Auto-play on launch and automatic reconnect can be turned on in **Settings** (⌘,) if your provider allows it. Playa cannot know what your other devices are doing, so watching on two devices at once is still up to you to avoid.

## Privacy

Playlist addresses usually contain your provider login. Playa keeps them on your Mac, in its preferences and in `~/Library/Application Support/Playa`, and only contacts the addresses in your playlist.

## Project layout

| Path | Contents |
|---|---|
| `Sources/PlayaCore` | Playlist, guide and series parsing. No UI; covered by tests. |
| `Sources/Playa` | The SwiftUI/AppKit app and the mpv player wrapper. |
| `Sources/Cmpv` | Module map exposing libmpv to Swift. |
| `Support` | `Info.plist`, the icon and the script that draws it. |

## Licence

Playa is released under the [MIT Licence](LICENSE). It links against mpv, which is licensed separately under the GPL/LGPL.
