# Playa privacy policy

Playa is a media player. It has no accounts, no analytics, no advertising and no server of its own. The developer never receives any information about you or about what you watch.

## What Playa stores, and where

- **On your device.** The playlists you add, a cached copy of each playlist and TV guide, your favourites, lists, hidden groups, recently watched items and resume positions. The playlists, their caches and everything derived from stream addresses are encrypted with a key kept in your device's Keychain, because playlist addresses often contain the login from your TV provider.
- **In your own iCloud account**, if you are signed in to iCloud. Playa uses iCloud key-value storage to keep your devices in step. This holds the addresses of your playlists, and your favourites, lists, hidden groups, recently watched items and resume positions. Apart from the playlist addresses, these are stored as fingerprints that do not reveal stream addresses. The data is protected by Apple's standard iCloud encryption and is not accessible to the developer. Playlists added from a file are not uploaded.

## What Playa connects to

Playa contacts the addresses contained in the playlists you add: the playlist itself, its TV guide, channel logos and the streams you choose to play. Those servers can see your IP address, as with any player or web browser.

When a stream has been waiting for data for a few seconds, Playa checks how fast your internet connection is, to tell you whether the slowness is on your side or the provider's. It does this by downloading test data for a few seconds from Apple's network quality server (mensura.cdn-apple.com), the same one macOS uses for its own speed test. Nothing is sent to it apart from the request itself, and Apple can see your IP address as with any server.

Playa does not contact any other service.

## Your choices

Removing a playlist in Playa removes it from your devices and from your iCloud storage. Deleting the app removes everything stored on the device. You can turn off iCloud for Playa in your device's iCloud settings; the app then keeps its data on the device only.

## Contact

Questions about this policy can be raised at https://github.com/myrmark/Playa/issues.

Last updated: 28 October 2026.
