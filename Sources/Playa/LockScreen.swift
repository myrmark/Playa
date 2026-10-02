import PlayaCore
import SwiftUI

/// Shown instead of the app's content while it is locked.
struct LockScreen: View {
    @EnvironmentObject private var lock: AppLock
    @State private var entry = ""
    @State private var message: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Playa is locked")
                .font(.title2.bold())
            SecureField("PIN", text: $entry)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                #if !os(tvOS)
                .textFieldStyle(.roundedBorder)
                #endif
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .focused($isFocused)
                .onSubmit(unlock)
            Button("Unlock", action: unlock)
                #if !os(tvOS)
                .keyboardShortcut(.defaultAction)
                #endif
                .disabled(entry.isEmpty)
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
    }

    private func unlock() {
        let wait = lock.secondsUntilNextAttempt
        if wait > 0 {
            message = "Too many wrong attempts. Try again in \(Self.duration(wait))."
        } else if !lock.unlock(with: entry) {
            let next = lock.secondsUntilNextAttempt
            message = next > 0 ? "Wrong PIN. Try again in \(Self.duration(next))." : "Wrong PIN."
        }
        entry = ""
    }

    private static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(Int((Double(seconds) / 60).rounded(.up))) minutes"
    }
}

/// The settings for turning the PIN lock on and off. Place inside a Form or List.
struct PINSettings: View {
    @EnvironmentObject private var lock: AppLock
    @State private var first = ""
    @State private var second = ""
    @State private var message: String?

    var body: some View {
        Section {
            if lock.isEnabled {
                pinField("Current PIN", text: $first)
                Button("Turn Off PIN Lock") {
                    if lock.turnOff(currentPIN: first) {
                        message = nil
                    } else {
                        let wait = lock.secondsUntilNextAttempt
                        message = wait > 0 ? "Wrong PIN. Wait \(wait) seconds before trying again." : "Wrong PIN."
                    }
                    first = ""
                }
                .disabled(first.isEmpty)
            } else {
                pinField("New PIN (4 to 8 digits)", text: $first)
                pinField("Repeat the PIN", text: $second)
                Button("Turn On PIN Lock") {
                    if first != second {
                        message = "The two entries don't match."
                    } else if lock.turnOn(pin: first) {
                        message = nil
                    } else {
                        message = "A PIN is 4 to 8 digits."
                    }
                    first = ""
                    second = ""
                }
                .disabled(first.isEmpty || second.isEmpty)
            }
        } header: {
            Text("PIN lock")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let message {
                    Text(message)
                        .foregroundStyle(.red)
                }
                Text(explanation)
            }
        }
    }

    private func pinField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            #if !os(macOS)
            .keyboardType(.numberPad)
            #endif
    }

    private var explanation: String {
        #if os(macOS)
        "Asks for the PIN each time Playa opens. The PIN is kept on this Mac only."
        #else
        "Asks for the PIN when Playa opens and when it comes back from the background. The PIN is kept on this device only. If you forget it, delete Playa and install it again: your playlists, favourites and lists return from iCloud."
        #endif
    }
}
