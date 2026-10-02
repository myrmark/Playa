import Foundation
import Security

/// Carries playlists, favourites and resume positions between the user's own devices through
/// their iCloud account. Playlist addresses contain the provider login, so they travel as an
/// iCloud Keychain item, which is end-to-end encrypted. Favourites and resume positions only
/// hold `Channel.key` fingerprints and use iCloud key-value storage.
///
/// Everything here quietly does nothing when the app has no iCloud entitlements (a plain
/// `swift build`) or the user isn't signed in to iCloud.
enum CloudSync {
    private static let store = NSUbiquitousKeyValueStore.default
    private static let secretService = "Playa.sync"

    /// Posted on the main queue when another device changed the key-value store.
    static var changes: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
    }

    #if os(tvOS)
    private static let platform = "Apple TV"
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
        ["Mac", "Apple TV"].map { name in
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

    private static func secretQuery(_ account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: secretService,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    static func readSecret<Value: Decodable>(_ type: Value.Type, account: String) -> Value? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(secretQuery(account).merging([kSecReturnData: true]) { $1 } as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Returns false when the Keychain refused, which is what happens without entitlements.
    @discardableResult
    static func writeSecret<Value: Encodable>(_ value: Value, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query = secretQuery(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging([
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrLabel: "Playa playlists",
            ]) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
