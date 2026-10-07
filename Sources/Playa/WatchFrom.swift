import PlayaCore
import SwiftUI

/// Picks a time to watch a channel's archive from, by hand: for when the guide has no
/// programme to go by. Nothing is played until Watch is pressed.
struct WatchFromPicker: View {
    let channelName: String
    /// How many days back the channel's archive reaches.
    let days: Int
    /// Called with the start and the length in minutes.
    let play: (Date, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var daysAgo = 0
    @State private var hour = 0
    @State private var minute = 0
    @State private var length = 120
    @State private var opened = Date()

    private static let lengths = [30, 60, 120, 180, 240]

    private var start: Date? {
        let calendar = Calendar.current
        guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: opened)) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// Why the chosen time can't be watched, if it can't.
    private var problem: String? {
        guard let start else { return "That time doesn't exist on that day." }
        if start >= Date() { return "That time hasn't been yet." }
        if Date().timeIntervalSince(start) >= Double(days) * 86_400 {
            return "The archive of this channel reaches \(days == 1 ? "one day" : "\(days) days") back."
        }
        return nil
    }

    private func dayName(_ daysAgo: Int) -> String {
        if daysAgo == 0 { return "Today" }
        if daysAgo == 1 { return "Yesterday" }
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: opened) ?? opened
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var fields: some View {
        Group {
            Picker("Day", selection: $daysAgo) {
                ForEach(0...max(days, 0), id: \.self) { Text(dayName($0)).tag($0) }
            }
            Picker("Hour", selection: $hour) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            Picker("Minute", selection: $minute) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            Picker("Length", selection: $length) {
                ForEach(Self.lengths, id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours").tag(minutes)
                }
            }
        }
    }

    private func watch() {
        guard problem == nil, let start else { return }
        play(start, length)
        dismiss()
    }

    var body: some View {
        content
            .onAppear {
                // Starts an hour back, on the hour: the likeliest thing to have just missed.
                opened = Date()
                let earlier = opened.addingTimeInterval(-3600)
                daysAgo = Calendar.current.isDate(earlier, inSameDayAs: opened) ? 0 : 1
                hour = Calendar.current.component(.hour, from: earlier)
                minute = 0
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch \(channelName) from…")
                .font(.headline)
                .lineLimit(1)
            Form { fields }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Watch", action: watch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 300)
        #else
        NavigationStack {
            Form {
                Section {
                    fields
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    Button("Watch", action: watch)
                        .disabled(problem != nil)
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .navigationTitle("Watch \(channelName) from…")
        }
        #endif
    }
}
