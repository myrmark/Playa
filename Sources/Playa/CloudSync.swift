import Foundation
import Security

/// Carries playlists, favourites and resume positions between the user's own devices through
/// iCloud key-value storage in their own account. Favourites and resume positions only hold
/// `Channel.key` fingerprints. Playlist addresses, which contain the provider login, are stored
/// as they are: iCloud encrypts them in transit and at rest, but not end to end.
///
/// Everything here quietly does nothing when the app has no iCloud entitlements (a plain
/// `swift build`) or the user isn't signed in to iCloud.
enum CloudSync {
    private static let store = NSUbiquitousKeyValueStore.default

    /// Posted on the main queue when another device changed the key-value store.
    static var changes: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
    }

    #if os(tvOS)
    private static let platform = "Apple TV"
    #elseif os(iOS)
    private static let platform = "iPhone or iPad"
    #else
    private static let platform = "Mac"
    #endif

    static func start() {
        store.synchronize()
        // Each kind of device leaves a timestamp, so `--diagnose` can show whether
        // key-value storage is reaching the other one.
        store.set(Date().timeIntervalSince1970, forKey: "lastSeen \(platform)")
    }

    /// When Playa last started on each kind of device, as far as this device has heard.
    static var lastSeen: String {
        ["Mac", "Apple TV", "iPhone or iPad"].map { name in
            let stamp = store.double(forKey: "lastSeen \(name)")
            return "\(name) " + (stamp == 0 ? "never" : Date(timeIntervalSince1970: stamp).formatted(date: .omitted, time: .standard))
        }.joined(separator: ", ")
    }

    static func read<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    static func write<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }

    /// Removes the playlist item earlier versions put in iCloud Keychain, which never reached Apple TV.
    static func removeLegacyKeychainItem() {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Playa.sync",
            kSecAttrAccount: "playlists",
            kSecAttrSynchronizable: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        SecItemDelete(query as CFDictionary)
    }
}
