import SwiftUI

struct SettingsView: View {
    static let autoplayKey = "autoplayOnLaunch"

    @AppStorage(SettingsView.autoplayKey) private var autoplayOnLaunch = false
    @AppStorage(MPVPlayer.autoReconnectKey) private var autoReconnect = false

    var body: some View {
        Form {
            Section {
                Toggle("Play the last channel when Playa opens", isOn: $autoplayOnLaunch)
                Toggle("Reconnect automatically when a live channel drops", isOn: $autoReconnect)
            } footer: {
                Text("Both are off by default. Many providers allow only one stream per subscription and may ban accounts that open a second one. With these on, Playa can start a stream while another device is already watching.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
