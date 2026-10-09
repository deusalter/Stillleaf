import SwiftUI
import BooksCore

/// Margins and gaps of the menu panel: one sheet of glass over the garden, edge to edge.
private enum PanelMetrics {
    /// From the panel's edge to the text, clear of the crisp vines at the edge.
    static let side: CGFloat = 30
    static let top: CGFloat = 26
    static let bottom: CGFloat = 24
    /// The band along the panel's edge where the garden is left crisp, unfrosted and unveiled.
    static let crispEdge: CGFloat = 12
    /// Between the header, the book, the goal, the streak and the actions.
    static let group: CGFloat = 18
    /// Height of everything outside the scrolling body: margins, header, actions and gaps.
    static let chrome: CGFloat = 150
}

@MainActor
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 640
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showingManualStart = false
    @State private var bodyHeight: CGFloat = 390
    /// The glass's frame for the garden to frost; a class so scrolling never re-renders the panel.
    @State private var frost = FrostRegions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let limit = max(160, maximumHeight - PanelMetrics.chrome)
        // The text sits straight on the glass; the garden shows softly through it everywhere.
        VStack(alignment: .leading, spacing: PanelMetrics.group) {
            header
            ScrollView {
                readingContent
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuBodyHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(bodyHeight, limit))
            .onPreferenceChange(MenuBodyHeight.self) { height in
                if height > 0, abs(height - bodyHeight) > 0.5 { bodyHeight = height }
            }
            if bodyHeight > limit {
                Label("Scroll for more", systemImage: "arrow.down")
                    .font(.caption2).foregroundStyle(ReadingPalette.ink)
                    .frame(maxWidth: .infinity)
            }
            actions
        }
        .id(theme.revision)
        .padding(.horizontal, PanelMetrics.side).padding(.top, PanelMetrics.top).padding(.bottom, PanelMetrics.bottom)
        .frame(width: 350)
        .foregroundStyle(ReadingPalette.ink)
        .environment(\.gardenBackdrop, true)
        .background {
            // The garden fills the panel, frosted under the glass and crisp only at the very edge.
            ZStack {
                MenuPanelGarden(day: model.today.day, mode: theme.effectiveGardenMode(reduceMotion: reduceMotion), frost: frost)
                PanelVeil()
            }
            .clipShape(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window, style: .continuous))
        }
        .background(GeometryReader { proxy in
            let inset = PanelMetrics.crispEdge
            Color.clear.preference(key: GlassRegionsKey.self, value: [GlassRegion(
                frame: proxy.frame(in: .named(GardenCanvas.space)).insetBy(dx: inset, dy: inset),
                cornerRadius: ReadingMetrics.Radius.window - inset)])
        })
        .coordinateSpace(name: GardenCanvas.space)
        .onPreferenceChange(GlassRegionsKey.self) { frost.rects = $0 }
        .nativePopoverSurface()
        .tint(ReadingPalette.accent).buttonStyle(ReadingButtonStyle())
        .readingMotionAccessibility()
        .sheet(isPresented: $showingManualStart) { ManualStartView(model: model).readingMotionAccessibility() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            PageleafMark().frame(width: 18, height: 18).foregroundStyle(ReadingPalette.accent)
            Text("Stillleaf").font(ReadingType.bookTitle(18))
                .accessibilityLabel("Stillleaf").accessibilityAddTraits(.isHeader)
            Spacer()
            Button { model.showDashboard() } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(ReadingButtonStyle(iconOnly: true)).controlSize(.small)
            .accessibilityLabel("Open dashboard").help("Open dashboard")
        }
    }

    private var actions: some View {
        ReadingGlassGroup {
            HStack {
                Button(model.manualActive ? "Stop manual reading" : "Read manually") {
                    if model.manualActive { model.stopManual() } else { showingManualStart = true }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: model.manualActive ? .primary : .secondary)).controlSize(.small)
                .fixedSize()
                Spacer()
                Menu {
                    Button("Settings…") { model.showDashboard(section: .settings) }
                    Divider()
                    Button("Quit Stillleaf") { model.quit() }
                } label: { Image(systemName: "ellipsis").frame(width: 12, height: 18) }
                .menuStyle(ReadingMenuStyle()).menuIndicator(.hidden)
                .accessibilityLabel("More actions")
            }
        }
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.group) {
            bookRow
            MenuReadingGoal(model: model)
            statsRow
            if model.appleBooksTrackingNeedsAccess {
                PopoverSetupNotice(icon: "accessibility", title: "Apple Books tracking needs access",
                    description: "Accessibility is required only for Apple Books. Stillleaf’s own reader records progress and time without it.") {
                    Button("Allow access") { model.requestAccessibility() }.controlSize(.small)
                }
            }
            if model.discordNeedsSetup {
                PopoverSetupNotice(icon: "key.horizontal", title: "Finish Discord setup",
                    description: "Add your Application ID in Settings.") {
                    Button("Sharing settings") { model.showDashboard(section: .settings, settingsCategory: .discord) }
                        .controlSize(.small)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var bookRow: some View {
        if let book = model.snapshot.book {
            HStack(alignment: .top, spacing: 12) {
                BookCoverView(book: book, size: .compact)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title).font(ReadingType.bookTitle(19))
                        .lineLimit(2).accessibilityLabel(book.title)
                    if let author = book.author, !author.isEmpty {
                        Text(author).font(.caption).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                    ActivityStateLabel(snapshot: model.snapshot, compact: true, onTranslucentSurface: true)
                        .fixedSize(horizontal: false, vertical: true)
                    if let page = model.currentPageText {
                        Text(page).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "book.closed").font(.system(size: 24, weight: .light))
                    .foregroundStyle(ReadingPalette.accent).frame(width: 30, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a book to begin").font(ReadingType.bookTitle(17))
                    ActivityStateLabel(snapshot: model.snapshot, compact: true, onTranslucentSurface: true)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 20) {
                if model.manualActive || model.snapshot.book != nil || model.sessionPages > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This session").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        Text("\(model.sessionPages) \(model.sessionPages == 1 ? "page" : "pages")")
                            .font(ReadingType.numeral(20)).monospacedDigit()
                        Text("\(ReadingFormat.duration(model.snapshot.sessionSeconds)) \(model.manualActive ? "manual" : "recorded")")
                            .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(model.dailyGoalStreak.current) \(model.dailyGoalStreak.current == 1 ? "day" : "days")", systemImage: "flame")
                        .font(ReadingType.numeral(20)).monospacedDigit()
                        .foregroundStyle(ReadingPalette.accent)
                    Text(model.dailyGoalStreak.todayPending ? "Goal streak · today still open" : "Goal streak")
                        .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                }.frame(maxWidth: .infinity, alignment: .leading)
                .help("Consecutive days that met your daily goal.")
            }
            if let pace = ReadingFormat.pagesPerMinute(model.sessionPagesPerMinute) {
                Label(pace, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
        }
    }
}

/// The glass the text sits on: the theme surface over the frosted garden, fading
/// out toward the panel's edge so the outermost vines stay crisp (see `PanelGlass`).
private struct PanelVeil: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.nativePreviewOpaque) private var previewOpaque
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let opaque = (previewOpaque ?? reduceTransparency) || contrast == .increased
        let edge = PanelMetrics.crispEdge
        ReadingPalette.surface.opacity(opaque ? 1 : PanelGlass.veilTint(dark: colorScheme == .dark))
            .mask(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window - edge, style: .continuous)
                .padding(edge).blur(radius: edge / 2))
    }
}

private struct MenuBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PopoverSetupNotice<Accessory: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ReadingPalette.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.control, style: .continuous)
            .stroke(ReadingPalette.warning.opacity(0.55), lineWidth: 1).allowsHitTesting(false))
    }
}
