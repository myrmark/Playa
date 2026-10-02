import Foundation
import PlayaCore

/// An optional PIN that locks the whole app, for instance so children can't use it unsupervised.
/// The PIN belongs to this device and is not synced.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isLocked = false

    private var pin: PINLock?
    private let defaults = UserDefaults.standard
    private static let key = "appLock"

    init() {
        if let sealed = defaults.data(forKey: Self.key), let data = Vault.open(sealed),
           let stored = try? JSONDecoder().decode(PINLock.self, from: data) {
            pin = stored
            isEnabled = true
            isLocked = true
        }
    }

    /// Seconds to wait after too many wrong guesses, or 0.
    var secondsUntilNextAttempt: Int {
        pin?.secondsUntilNextAttempt() ?? 0
    }

    func lock() {
        if isEnabled { isLocked = true }
    }

    func unlock(with entry: String) -> Bool {
        guard verify(entry) else { return false }
        isLocked = false
        return true
    }

    /// Returns false if `newPIN` isn't 4 to 8 digits.
    func turnOn(pin newPIN: String) -> Bool {
        guard let lock = PINLock(pin: newPIN) else { return false }
        pin = lock
        isEnabled = true
        save()
        return true
    }

    /// Turning the lock off takes the current PIN.
    func turnOff(currentPIN: String) -> Bool {
        guard verify(currentPIN) else { return false }
        pin = nil
        isEnabled = false
        isLocked = false
        defaults.removeObject(forKey: Self.key)
        return true
    }

    private func verify(_ entry: String) -> Bool {
        guard var lock = pin else { return false }
        let isCorrect = lock.verify(entry)
        // Wrong guesses are remembered across launches, so restarting the app doesn't reset the wait.
        pin = lock
        save()
        return isCorrect
    }

    private func save() {
        if let pin, let data = try? JSONEncoder().encode(pin), let sealed = Vault.seal(data) {
            defaults.set(sealed, forKey: Self.key)
        }
    }
}
