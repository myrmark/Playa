import PlayaCore
import SwiftUI

/// Sheet for choosing which of the playlist's groups to show.
struct GroupChooser: View {
    @ObservedObject var store: PlaylistStore
    @State var kind: ChannelKind
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var groups: [String] {
        let all = store.playlist.groupsByKind[kind] ?? []
        return searchText.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func isHidden(_ group: String) -> Bool {
        store.hiddenGroups.contains(PlaylistStore.hiddenKey(group: group, kind: kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Groups")
                .font(.headline)
            Text("Untick the groups you never use. They disappear from the group menu, from “All” and from search. Channels you put in Favourites or a list stay there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Section", selection: $kind) {
                ForEach(ChannelKind.allCases.filter { store.playlist.groupsByKind[$0] != nil }, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Filter groups", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(groups, id: \.self) { group in
                Toggle(group, isOn: Binding(
                    get: { !isHidden(group) },
                    set: { store.setHidden(!$0, groups: [group], kind: kind) }
                ))
            }
            .listStyle(.bordered)
            .frame(height: 340)

            HStack {
                // Both act on the groups listed above, so a filter narrows what they change.
                Button("Show All") { store.setHidden(false, groups: groups, kind: kind) }
                Button("Hide All") { store.setHidden(true, groups: groups, kind: kind) }
                Spacer()
                Text("\(groups.filter { !isHidden($0) }.count) of \(groups.count) shown")
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
