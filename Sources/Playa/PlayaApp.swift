import AppKit
import SwiftUI

@main
struct PlayaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lock = AppLock()
    @StateObject private var playback = PlaybackCommands()

    var body: some Scene {
        Window("Playa", id: "main") {
            Group {
                // The app's content isn't even created until the PIN has been entered.
                if lock.isLocked {
                    LockScreen()
                } else {
                    ContentView()
                }
            }
            // Narrow enough for half of a 13-inch screen.
            .frame(minWidth: 640, minHeight: 420)
            .environmentObject(lock)
            .environmentObject(playback)
        }
        .defaultSize(width: 1280, height: 760)
        .commands { PlaybackMenu(commands: playback) }

        Settings {
            SettingsView()
                .environmentObject(lock)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `Playa.app/Contents/MacOS/Playa --diagnose` reports storage and sync state and quits.
        if CommandLine.arguments.contains("--diagnose") {
            print(PlaylistStore().diagnostics)
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
