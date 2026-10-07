import SwiftUI

/// Settings → Appearance. Swatches preview each theme in the current light or
/// dark appearance; choices apply live and persist immediately.
@MainActor
struct AppearancePicker: View {
    @ObservedObject var store: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ReadingMetrics.Space.xl) {
            ReadingSection("Display") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Appearance", description: "System follows your Mac’s appearance.") {
                        GlassSegmentedControl(
                            label: "Display mode",
                            options: DashboardAppearance.allCases,
                            selection: Binding(get: { store.appearanceMode }, set: { store.select(appearance: $0) }),
                            title: { $0.label },
                            systemImage: { mode in
                                switch mode {
                                case .system: return "desktopcomputer"
                                case .light: return "sun.max"
                                case .dark: return "moon"
                                }
                            }
                        )
                        .frame(width: 390)
                        .accessibilityIdentifier("dashboard-appearance-mode")
                    }
                    SettingsDivider()
                    SettingsRow(title: "Garden", description: "Animated vines grow when a window opens, then breathe. Still shows them without motion. Reduce Motion and Low Power use Still.") {
                        GlassSegmentedControl(
                            label: "Garden",
                            options: GardenMode.allCases,
                            selection: Binding(get: { store.gardenMode }, set: { store.select(garden: $0) }),
                            title: { $0.label },
                            systemImage: { mode in
                                switch mode {
                                case .animated: return "leaf"
                                case .still: return "pause.circle"
                                case .off: return "circle.slash"
                                }
                            }
                        )
                        .frame(width: 390)
                        .accessibilityIdentifier("dashboard-garden-mode")
                    }
                }
            }
            ReadingSection("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140, maximum: 240), spacing: 18, alignment: .top), count: 3),
                          alignment: .leading, spacing: 18) {
                    ForEach(ReadingTheme.all) { theme in
                        ThemeSwatch(theme: theme, dark: colorScheme == .dark, selected: store.themeID == theme.id) {
                            store.select(theme: theme.id)
                        }
                    }
                }
            }
            ReadingSection("Accent") {
                SettingsRow(title: accentName, description: "Tints buttons, selections and the vines.") {
                    HStack(spacing: 8) {
                        AccentDot(name: "Theme default", color: ReadingPalette.fixed(store.theme.colors(dark: colorScheme == .dark, accent: nil).accent),
                                  selected: store.accentID == nil, showsDefaultMark: true) { store.select(accent: nil) }
                        ForEach(AccentPreset.all) { accent in
                            AccentDot(name: accent.name, color: ReadingPalette.fixed(colorScheme == .dark ? accent.dark : accent.light),
                                      selected: store.accentID == accent.id) { store.select(accent: accent.id) }
                        }
                    }
                }
            }
        }
    }

    private var accentName: String {
        AccentPreset.all.first { $0.id == store.accentID }?.name ?? "Theme default"
    }
}

struct ThemeSwatch: View {
    let theme: ReadingTheme
    let dark: Bool
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = theme.colors(dark: dark, accent: nil)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ReadingPalette.fixed(colors.canvas))
                    HStack(spacing: 0) {
                        Rectangle().fill(ReadingPalette.fixed(colors.canvas)).frame(width: 34)
                        Rectangle().fill(ReadingPalette.fixed(colors.border)).frame(width: 1)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(ReadingPalette.fixed(colors.ink)).frame(width: 56, height: 7)
                            Capsule().fill(ReadingPalette.fixed(colors.secondaryInk)).frame(width: 78, height: 4)
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ReadingPalette.fixed(colors.surface))
                                .frame(height: 30)
                                .overlay(alignment: .leading) {
                                    HStack(spacing: 5) {
                                        Capsule().fill(ReadingPalette.fixed(colors.accent)).frame(width: 34, height: 6)
                                        Capsule().fill(ReadingPalette.fixed(colors.chart[1])).frame(width: 14, height: 6)
                                    }.padding(.leading, 8)
                                }
                        }
                        .padding(10)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2).fill(ReadingPalette.fixed(index == 0 ? colors.accent : colors.secondaryInk).opacity(index == 0 ? 1 : 0.5))
                                .frame(width: 16, height: 4)
                        }
                    }.padding(.leading, 9).padding(.top, 14)
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? ReadingPalette.accent : ReadingPalette.border, lineWidth: selected ? 2 : 1))
                .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
                HStack(spacing: 5) {
                    Text(theme.name).font(.callout.weight(selected ? .semibold : .regular))
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(ReadingPalette.accent) }
                }
                .foregroundStyle(ReadingPalette.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .accessibilityLabel("Theme: \(theme.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AccentDot: View {
    let name: String
    let color: Color
    let selected: Bool
    var showsDefaultMark = false
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            ZStack {
                Circle().fill(color).frame(width: 24, height: 24)
                if showsDefaultMark {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ReadingPalette.canvas)
                }
            }
            .padding(3)
            .overlay(Circle().stroke(selected ? ReadingPalette.ink : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Accent: \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
