import CryptoKit
import Foundation
import Security

/// Encrypts what Playa stores about playlists. Provider logins are part of the playlist
/// address and of every stream address in it, so the cached playlist, favourites, resume
/// positions and last channel are all sealed with a key that lives in the Keychain.
enum Vault {
    private static let key: SymmetricKey? = loadKey()

    /// False when the Keychain key can't be read; nothing is written in that state,
    /// so existing data is never replaced by something that can't be opened later.
    static var isAvailable: Bool { key != nil }

    static func seal(_ data: Data) -> Data? {
        guard let key else { return nil }
        return try? ChaChaPoly.seal(data, using: key).combined
    }

    static func open(_ sealed: Data) -> Data? {
        guard let key, let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    private static func loadKey() -> SymmetricKey? {
        guard let service = Bundle.main.bundleIdentifier else {
            return developmentKey()
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "vault-key",
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData: true]) { $1 } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            FileHandle.standardError.write(Data("Playa: could not read its Keychain key (status \(status)).\n".utf8))
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let added = SecItemAdd(query.merging([
            kSecValueData: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel: "Playa playlist encryption key",
        ]) { $1 } as CFDictionary, nil)
        return added == errSecSuccess ? key : nil
    }

    /// A bare executable (`swift run`) has no stable signature, so the Keychain would ask for
    /// permission on every build. Development runs keep their key in a plain file instead;
    /// the packaged app never takes this path.
    private static func developmentKey() -> SymmetricKey? {
        let file = Storage.directory.appendingPathComponent("development-vault-key")
        if let data = try? Data(contentsOf: file), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try? key.withUnsafeBytes { Data($0) }.write(to: file, options: .atomic)
        return key
    }
}
