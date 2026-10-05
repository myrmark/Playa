import Foundation
import PlayaCore
import SwiftUI
import UserNotifications

/// Notifications shortly before followed broadcasts start. A choice per device, not synced:
/// a reminder belongs where it is wanted. Scheduled whenever the Following search runs, for
/// the next two days, so they arrive even when Playa isn't open.
enum Reminders {
    static let enabledKey = "remindersEnabled"
    static let leadKey = "reminderMinutes"
    static let leadChoices = [5, 10, 15, 30]

    private static let prefix = "follow."
    /// iOS keeps at most 64 pending notifications per app.
    private static let maximum = 50

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var leadMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: leadKey)
        return stored > 0 ? stored : 10
    }

    /// Asks for permission. Returns whether notifications may be shown.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func schedule(_ broadcasts: [Broadcast], now: Date = Date()) {
        // Notifications need an app bundle; the bare test binary has none and would crash.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        guard isEnabled else {
            removeAll()
            return
        }
        let lead = TimeInterval(leadMinutes * 60)
        let upcoming = broadcasts
            .filter { $0.programme.start.addingTimeInterval(-lead) > now && $0.programme.start < now.addingTimeInterval(2 * 86_400) }
            .prefix(maximum)
        var wanted: [String: UNNotificationRequest] = [:]
        for broadcast in upcoming {
            let content = UNMutableNotificationContent()
            content.title = broadcast.programme.title
            let time = broadcast.programme.start.formatted(date: .omitted, time: .shortened)
            let channels = broadcast.channels.prefix(2).map(\.name).joined(separator: ", ")
            content.body = channels.isEmpty ? "Starts at \(time)" : "Starts at \(time) on \(channels)"
            content.sound = .default
            let fire = broadcast.programme.start.addingTimeInterval(-lead)
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire),
                repeats: false
            )
            let id = prefix + broadcast.id
            wanted[id] = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }
        center.getPendingNotificationRequests { pending in
            let ours = pending.filter { $0.identifier.hasPrefix(prefix) }
            // Replaced rather than kept, so a changed lead time or channel list takes effect.
            center.removePendingNotificationRequests(withIdentifiers: ours.map(\.identifier))
            for request in wanted.values { center.add(request) }
        }
    }

    static func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
    }
}

extension Reminders {
    /// Posted when the reminder settings change, so the schedule can be rebuilt.
    static let settingsChanged = Notification.Name("Playa.remindersChanged")
}

/// The reminder settings. Place inside a Form or List.
struct ReminderSettings: View {
    @AppStorage(Reminders.enabledKey) private var isEnabled = false
    @AppStorage(Reminders.leadKey) private var leadMinutes = 10
    @State private var isDenied = false

    var body: some View {
        Section {
            Toggle("Remind me before followed broadcasts", isOn: Binding(
                get: { isEnabled },
                set: { wanted in
                    guard wanted else {
                        isEnabled = false
                        NotificationCenter.default.post(name: Reminders.settingsChanged, object: nil)
                        return
                    }
                    Task {
                        let allowed = await Reminders.requestPermission()
                        isDenied = !allowed
                        isEnabled = allowed
                        NotificationCenter.default.post(name: Reminders.settingsChanged, object: nil)
                    }
                }
            ))
            if isEnabled {
                Picker("How long before", selection: $leadMinutes) {
                    ForEach(Reminders.leadChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .onChange(of: leadMinutes) {
                    NotificationCenter.default.post(name: Reminders.settingsChanged, object: nil)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if isDenied {
                    Text("Notifications are turned off for Playa in System Settings.")
                        .foregroundStyle(.red)
                }
                Text("A notification before each broadcast on your Following list in the next two days. Set on each device separately. The list is brought up to date whenever Playa loads the TV guide.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
