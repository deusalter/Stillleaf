import SwiftUI
import BooksCore

@MainActor
struct AppearancePicker: View {
    @ObservedObject var store: ThemeStore
    let goal: DailyGoalProgress
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            gardenPreview
            appearanceGroup("Theme") {
                // The supported dashboard widths fit all six palettes on one line.
                HStack(spacing: 9) {
                    ForEach(ReadingTheme.all) { theme in
                        PaletteStrip(theme: theme, dark: colorScheme == .dark, selected: store.themeID == theme.id) {
                            store.select(theme: theme.id)
                        }
                    }
                }
            }
            appearanceGroup("Color & display") {
                SettingsRow(title: "Accent color", description: store.accent?.name ?? "Theme default") {
                    HStack(spacing: 5) {
                        AccentDot(name: "Theme default", color: ReadingPalette.fixed(store.theme.colors(dark: colorScheme == .dark, accent: nil).accent),
                                  selected: store.accentID == nil, showsDefaultMark: true) { store.select(accent: nil) }
                        ForEach(AccentPreset.all) { accent in
                            AccentDot(name: accent.name, color: ReadingPalette.fixed(colorScheme == .dark ? accent.dark : accent.light),
                                      selected: store.accentID == accent.id) { store.select(accent: accent.id) }
                        }
                    }
                    .help("Tints buttons, selections and the vines.")
                }
                SettingsDivider()
                SettingsRow(title: "Appearance", description: "System follows your Mac.") {
                    Picker("Display mode", selection: Binding(get: { store.appearanceMode }, set: { store.select(appearance: $0) })) {
                        ForEach(DashboardAppearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 196)
                    .accessibilityIdentifier("dashboard-appearance-mode")
                }
            }
            appearanceGroup("Garden") {
                SettingsRow(title: "Vine motion", description: "Reduce Motion and Low Power use still vines.") {
                    Picker("Garden", selection: Binding(get: { store.gardenMode }, set: { store.select(garden: $0) })) {
                        ForEach(GardenMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 196)
                    .accessibilityIdentifier("dashboard-garden-mode")
                }
            }
        }
    }

    private func appearanceGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(ReadingType.sectionTitle).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content() }
        }
    }

    private var gardenPreview: some View {
        let mode = store.effectiveGardenMode(reduceMotion: previewReduceMotion ?? reduceMotion)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dashboard preview").font(.caption.weight(.semibold)).foregroundStyle(ReadingPalette.secondaryInk)
                Text("Reading garden").font(.system(size: 32, design: .serif))
                Text(goal.target == nil ? "\(goal.displayValue) \(goal.todayLabel)" : "\(goal.displayValue) of \(goal.targetText) today")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                if goal.target != nil {
                    Capsule().fill(ReadingPalette.track)
                        .frame(width: 100, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ReadingPalette.accent)
                                .frame(width: 100 * min(1, max(0, goal.fraction)))
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, 22)
            Spacer(minLength: 8)
            if mode != .off {
                FieldGuideFronds(ink: ReadingPalette.accent, wash: ReadingPalette.elevated,
                                 animated: mode == .animated && GardenClock.frozenTime == nil)
                    .frame(maxWidth: 310)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 126)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct PaletteStrip: View {
    let theme: ReadingTheme
    let dark: Bool
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        let colors = theme.colors(dark: dark, accent: nil)
        let shape = RoundedRectangle(cornerRadius: 7)
        Button(action: choose) {
            VStack(spacing: 0) {
                GeometryReader { bounds in
                    HStack(spacing: 0) {
                        ReadingPalette.fixed(colors.accent).frame(width: bounds.size.width * 0.625)
                        ReadingPalette.fixed(colors.elevated).frame(width: bounds.size.width * 0.25)
                        ReadingPalette.fixed(colors.canvas)
                    }
                }
                .frame(height: 26)
                HStack(spacing: 2) {
                    Text(theme.name).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").imageScale(.small) }
                }
                .font(.caption.weight(selected ? .bold : .medium))
                .padding(.horizontal, 7).frame(height: 25)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? ReadingPalette.accent : ReadingPalette.border, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Theme: \(theme.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
