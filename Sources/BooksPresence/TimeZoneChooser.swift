import SwiftUI

/// The full zone list exists only while the chooser is open. A native Picker with
/// hundreds of children eagerly constructed all of them on every Settings visit.
struct TimeZoneChooser: View {
    @Binding var selection: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 8) {
                Text(selection.replacingOccurrences(of: "_", with: " ")).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("Calendar time zone")
        .accessibilityValue(selection)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TimeZoneSearch(selection: $selection, dismiss: { isPresented = false })
        }
    }
}

private struct TimeZoneSearch: View {
    @Binding var selection: String
    let dismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    // Localized labels are prepared once per opening, not on every keystroke.
    @State private var zones: [Zone] = []

    private struct Zone: Identifiable {
        let id: String
        let label: String
        let searchText: String
        init(_ id: String) {
            self.id = id
            let name = TimeZone(identifier: id)?.localizedName(for: .standard, locale: .current)
            label = name.map { "\($0) — \(id)" } ?? id
            searchText = label.replacingOccurrences(of: "_", with: " ")
        }
    }
    private var matches: [Zone] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ")
        return query.isEmpty ? zones : zones.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calendar time zone").font(.headline)
            TextField("Search by city, region, or time zone", text: $search)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(matches) { zone in
                        Button {
                            selection = zone.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(zone.label).font(.callout).multilineTextAlignment(.leading)
                                Spacer()
                                if selection == zone.id { Image(systemName: "checkmark").foregroundStyle(ReadingPalette.accent) }
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(selection == zone.id ? ReadingPalette.accent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == zone.id ? .isSelected : [])
                    }
                    if matches.isEmpty { Text("No matching time zones").foregroundStyle(ReadingPalette.secondaryInk).padding(8) }
                }
            }
        }
        .padding(16).frame(width: 440, height: 340)
        .onAppear {
            var identifiers = TimeZone.knownTimeZoneIdentifiers
            if !identifiers.contains(selection) { identifiers.insert(selection, at: 0) }
            zones = identifiers.map(Zone.init)
            searchFocused = true
        }
    }
}
