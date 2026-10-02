import AppKit
import SwiftUI

@main
struct PlayaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Playa", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 760)

        Settings {
            SettingsView()
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
