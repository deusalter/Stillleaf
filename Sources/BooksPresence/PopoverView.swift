import SwiftUI
import BooksCore

/// Gutters and gaps of the menu panel. The vines grow in the gutters; the glass cards sit inside them.
private enum PanelMetrics {
    /// Beside the cards, wide enough for a side vine (`MenuPanelGarden.sideWidth`).
    static let side: CGFloat = 22
    static let top: CGFloat = 38
    static let bottom: CGFloat = 42
    static let gap: CGFloat = 10
    /// Room a scrolling card needs for its shadow before the scroll view clips it.
    static let shadowBleed: CGFloat = 10
    /// Height of everything outside the scrolling body: gutters, header, actions and gaps.
    static let chrome: CGFloat = 200
}

@MainActor
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 640
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showingManualStart = false
    @State private var bodyHeight: CGFloat = 390
    /// Card frames for the garden to frost; a class so scrolling never re-renders the cards.
    @State private var frost = FrostRegions()
    /// The scroll view's frame in the garden's space; cards scrolled partly out of it frost only what shows.
    @State private var scrollFrame = CGRect.null
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let limit = max(160, maximumHeight - PanelMetrics.chrome)
        VStack(alignment: .leading, spacing: PanelMetrics.gap) {
            header
            ScrollView {
                readingContent
                    .padding(.horizontal, PanelMetrics.side).padding(.vertical, PanelMetrics.shadowBleed)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuBodyHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(bodyHeight, limit + 2 * PanelMetrics.shadowBleed))
            // The scroll view spans the panel so card shadows are not clipped at the gutters.
            .padding(.horizontal, -PanelMetrics.side).padding(.vertical, -PanelMetrics.shadowBleed)
            // An overlay, not a background: a background's frame is never delivered for a scroll view.
            .overlay(GeometryReader { proxy in
                Color.clear.preference(key: MenuScrollFrame.self, value: proxy.frame(in: .named(GardenCanvas.space)))
            }.allowsHitTesting(false))
            .onPreferenceChange(MenuScrollFrame.self) { scrollFrame = $0 }
            .transformPreference(GlassRegionsKey.self) { regions in
                guard !scrollFrame.isNull else { return }
                // Negative padding shrinks the measured frame; the scroll view shows the bleed too.
                let visible = scrollFrame.insetBy(dx: -PanelMetrics.side, dy: -PanelMetrics.shadowBleed)
                regions = regions.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
            }
            .onPreferenceChange(MenuBodyHeight.self) { height in
                if height > 0, abs(height - bodyHeight) > 0.5 { bodyHeight = height }
            }
            if bodyHeight > limit + 2 * PanelMetrics.shadowBleed {
                Label("Scroll for more", systemImage: "arrow.down")
                    .font(.caption2).foregroundStyle(ReadingPalette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .glassSurface(cornerRadius: ReadingMetrics.Radius.control)
                    .frame(maxWidth: .infinity)
            }
            actions
        }
        .id(theme.revision)
        .padding(.horizontal, PanelMetrics.side).padding(.top, PanelMetrics.top).padding(.bottom, PanelMetrics.bottom)
        .frame(width: 350)
        .foregroundStyle(ReadingPalette.ink)
        .environment(\.gardenBackdrop, true)
        .environment(\.glassOverDesktop, true)
        .background {
            // Vines in the gutters around the cards, clear of any text.
            MenuPanelGarden(day: model.today.day, mode: theme.effectiveGardenMode(reduceMotion: reduceMotion), frost: frost)
                .clipShape(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window, style: .continuous))
        }
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
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassSurface(cornerRadius: ReadingMetrics.Radius.card)
    }

    private var actions: some View {
        ReadingGlassGroup {
            HStack {
                Button(model.manualActive ? "Stop manual reading" : "Read manually") {
                    if model.manualActive { model.stopManual() } else { showingManualStart = true }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: model.manualActive ? .primary : .secondary)).controlSize(.small)
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
        .menuCard(padding: 10)
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.gap) {
            bookCard
            MenuReadingGoal(model: model).menuCard()
            statsCard
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

    @ViewBuilder private var bookCard: some View {
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
            .menuCard()
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
            .menuCard()
        }
    }

    private var statsCard: some View {
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
        .menuCard()
    }
}

private extension View {
    /// A glass card for one block of the panel's text.
    func menuCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: ReadingMetrics.Radius.card)
    }
}

private struct MenuScrollFrame: PreferenceKey {
    static var defaultValue = CGRect.null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
        .menuCard()
        .overlay(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.card, style: .continuous)
            .stroke(ReadingPalette.warning.opacity(0.55), lineWidth: 1).allowsHitTesting(false))
    }
}
