import SwiftUI

/// What the Playback menu can do, filled in by the window: the menu lives at app level, the
/// player and the channel list inside the window. Being real menu items, the shortcuts can be
/// changed in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts.
@MainActor
final class PlaybackCommands: ObservableObject {
    @Published var hasChannel = false
    @Published var isPaused = true
    @Published var isMuted = false
    @Published var isLive = true
    @Published var hasGuide = false
    @Published var canRefreshGuide = false
    /// Off while a text field is being typed in, where plain keys like Space and M must type.
    @Published var keysFree = true
    /// The channel before the current one, to switch back to.
    @Published var lastChannelName: String?
    @Published var sleepAt: Date?
    /// The two sizes of skip in what is playing, in seconds; 0 when there is nothing to skip in.
    @Published var skipSmall = 0
    @Published var skipBig = 0

    var togglePause: () -> Void = {}
    var toggleMute: () -> Void = {}
    var changeVolume: (Double) -> Void = { _ in }
    var zap: (Int) -> Void = { _ in }
    var backToLastChannel: () -> Void = {}
    var toggleFavourite: () -> Void = {}
    var showGuide: () -> Void = {}
    var refreshGuide: () -> Void = {}
    var showFollowing: () -> Void = {}
    var setSleepTimer: (Int?) -> Void = { _ in }
    /// Skips so many seconds forward, or back when negative.
    var skip: (Int) -> Void = { _ in }
}

private func skipTitle(_ seconds: Int, forward: Bool) -> String {
    let amount = seconds < 60 ? "\(seconds) Seconds" : seconds == 60 ? "1 Minute" : "\(seconds / 60) Minutes"
    return "Skip \(forward ? "Forward" : "Back") \(seconds > 0 ? amount : "")".trimmingCharacters(in: .whitespaces)
}

struct PlaybackMenu: Commands {
    @ObservedObject var commands: PlaybackCommands

    var body: some Commands {
        CommandMenu("Playback") {
            Button(commands.isPaused ? "Play" : "Pause", action: commands.togglePause)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!commands.hasChannel || !commands.keysFree)
            Divider()
            Button("Previous Channel") { commands.zap(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!commands.hasChannel || !commands.isLive)
            Button("Next Channel") { commands.zap(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!commands.hasChannel || !commands.isLive)
            Button(commands.lastChannelName.map { "Back to \($0)" } ?? "Back to Last Channel", action: commands.backToLastChannel)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(commands.lastChannelName == nil)
            Divider()
            // The arrow keys must stay with the text field while something is being typed.
            Button(skipTitle(commands.skipSmall, forward: false)) { commands.skip(-commands.skipSmall) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(commands.skipSmall == 0 || !commands.keysFree)
            Button(skipTitle(commands.skipSmall, forward: true)) { commands.skip(commands.skipSmall) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(commands.skipSmall == 0 || !commands.keysFree)
            Button(skipTitle(commands.skipBig, forward: false)) { commands.skip(-commands.skipBig) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
                .disabled(commands.skipBig == 0 || !commands.keysFree)
            Button(skipTitle(commands.skipBig, forward: true)) { commands.skip(commands.skipBig) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
                .disabled(commands.skipBig == 0 || !commands.keysFree)
            Divider()
            Button(commands.isMuted ? "Unmute" : "Mute", action: commands.toggleMute)
                .keyboardShortcut("m", modifiers: [])
                .disabled(!commands.keysFree)
            Button("Volume Up") { commands.changeVolume(5) }
                .keyboardShortcut("+", modifiers: [])
                .disabled(!commands.keysFree)
            Button("Volume Down") { commands.changeVolume(-5) }
                .keyboardShortcut("-", modifiers: [])
                .disabled(!commands.keysFree)
            Divider()
            Button("Add to or Remove from Favourites", action: commands.toggleFavourite)
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!commands.hasChannel)
            Button("TV Guide", action: commands.showGuide)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!commands.hasGuide)
            Button("Refresh TV Guide", action: commands.refreshGuide)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!commands.canRefreshGuide)
            Button("Following", action: commands.showFollowing)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Menu(commands.sleepAt.map { "Sleep Timer (stops at \($0.formatted(date: .omitted, time: .shortened)))" } ?? "Sleep Timer") {
                Button("Off") { commands.setSleepTimer(nil) }
                    .disabled(commands.sleepAt == nil)
                ForEach([15, 30, 60, 90, 120], id: \.self) { minutes in
                    Button("In \(minutes) Minutes") { commands.setSleepTimer(minutes) }
                }
            }
            .disabled(!commands.hasChannel)
        }
    }
}
