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
            #if os(tvOS)
            PINPad(entry: $entry, doneTitle: "Unlock", onDone: unlock)
            #else
            SecureField("PIN", text: $entry)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .focused($isFocused)
                .onSubmit(unlock)
                .digitsOnly($entry)
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(entry.isEmpty)
            #endif
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { isFocused = true }
        // The last digit unlocks, without a press on the button.
        .onChange(of: entry) { _, value in
            if value.count == lock.pinLength { unlock() }
        }
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
            #if os(tvOS)
            NavigationLink(lock.isEnabled ? "Turn Off PIN Lock…" : "Turn On PIN Lock…") { PINSetupScreen() }
            #else
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
            #endif
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

    #if !os(tvOS)
    private func pinField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .digitsOnly(text)
    }
    #endif

    private var explanation: String {
        #if os(macOS)
        "Asks for the PIN each time Playa opens. The PIN is kept on this Mac only."
        #else
        "Asks for the PIN when Playa opens and when it comes back from the background. The PIN is kept on this device only. If you forget it, delete Playa and install it again: your playlists, favourites and lists return from iCloud."
        #endif
    }
}

#if os(tvOS)
/// A grid of digit buttons, so a PIN can be entered with the remote without the full keyboard.
struct PINPad: View {
    @Binding var entry: String
    let doneTitle: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(entry.isEmpty ? " " : String(repeating: "●", count: entry.count))
                .font(.title3)
                .frame(height: 50)
            Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(1..<4, id: \.self) { column in
                            digit(row * 3 + column)
                        }
                    }
                }
                GridRow {
                    Button {
                        if !entry.isEmpty { entry.removeLast() }
                    } label: {
                        Image(systemName: "delete.left").frame(width: 80)
                    }
                    .disabled(entry.isEmpty)
                    digit(0)
                    Button(action: onDone) {
                        Image(systemName: "checkmark").frame(width: 80)
                    }
                    .disabled(entry.isEmpty)
                    .accessibilityLabel(doneTitle)
                }
            }
        }
        .focusSection()
    }

    private func digit(_ value: Int) -> some View {
        Button {
            if entry.count < 8 { entry.append(String(value)) }
        } label: {
            Text(String(value)).frame(width: 80)
        }
    }
}

/// Turns the PIN lock on (enter it twice) or off (enter the current one), using the digit pad.
private struct PINSetupScreen: View {
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    /// The first entry of a new PIN, while it is being repeated.
    @State private var first: String?
    @State private var message: String?
    /// Fixed for the life of the screen, so it doesn't change under the user as the lock toggles.
    @State private var isTurningOff: Bool?

    var body: some View {
        VStack(spacing: 24) {
            Text(title)
                .font(.title3.bold())
            PINPad(entry: $entry, doneTitle: "Done", onDone: submit)
            Text(message ?? " ")
                .foregroundStyle(.secondary)
        }
        .onAppear { if isTurningOff == nil { isTurningOff = lock.isEnabled } }
    }

    private var title: String {
        if isTurningOff == true { return "Enter the current PIN" }
        return first == nil ? "Choose a PIN of 4 to 8 digits" : "Repeat the PIN"
    }

    private func submit() {
        defer { entry = "" }
        if isTurningOff == true {
            if lock.turnOff(currentPIN: entry) {
                dismiss()
            } else {
                let wait = lock.secondsUntilNextAttempt
                message = wait > 0 ? "Wrong PIN. Wait \(wait) seconds before trying again." : "Wrong PIN."
            }
        } else if let chosen = first {
            if chosen == entry, lock.turnOn(pin: chosen) {
                dismiss()
            } else {
                first = nil
                message = "The two entries don't match. Start again."
            }
        } else if PINLock.isValid(entry) {
            first = entry
            message = nil
        } else {
            message = "A PIN is 4 to 8 digits."
        }
    }
}
#else
private extension View {
    /// Drops anything typed that isn't a digit, and stops at the longest PIN.
    func digitsOnly(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, value in
            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(8))
            if digits != value { text.wrappedValue = digits }
        }
    }
}
#endif
