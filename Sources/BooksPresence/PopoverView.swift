import SwiftUI
import BooksCore

@MainActor
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 640
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showingManualStart = false
    @State private var bodyHeight: CGFloat = 390
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                PageleafMark().frame(width: 18, height: 18).foregroundStyle(ReadingPalette.accent)
                Text("Stillleaf").font(.system(size: 16, weight: .regular, design: .serif))
                    .accessibilityLabel("Stillleaf")
                Spacer()
                Button { model.showDashboard() } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(ReadingButtonStyle(iconOnly: true)).controlSize(.small)
                .accessibilityLabel("Open dashboard").help("Open dashboard")
            }
            ScrollView {
                readingContent
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: MenuBodyHeight.self, value: geometry.size.height)
                    })
            }
            .frame(height: min(bodyHeight, max(160, maximumHeight - 160)))
            .onPreferenceChange(MenuBodyHeight.self) { height in
                if height > 0, abs(height - bodyHeight) > 0.5 { bodyHeight = height }
            }
            if bodyHeight > max(160, maximumHeight - 160) {
                Label("Scroll for more", systemImage: "arrow.down")
                    .font(.caption2).foregroundStyle(ReadingPalette.ink)
                    .frame(maxWidth: .infinity)
            }
            Hairline()
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
        }
        .id(theme.revision)
        .padding(18).frame(width: 350)
        .foregroundStyle(ReadingPalette.ink)
        .background {
            // A sparse vine trellis in the panel's edge padding, clear of its text.
            GardenCanvas(layout: GardenLayout(seed: GardenSeed.daily("popover", day: model.today.day), roots: 0, pollen: false,
                                              cornerRoots: [.bottomTrailing, .topTrailing], budget: 200, edgeBand: 2, bandEdges: [.trailing]),
                         mode: theme.effectiveGardenMode(reduceMotion: reduceMotion))
                .clipShape(RoundedRectangle(cornerRadius: ReadingMetrics.Radius.window, style: .continuous))
        }
        .nativePopoverSurface()
        .tint(ReadingPalette.accent).buttonStyle(ReadingButtonStyle())
        .readingMotionAccessibility()
        .sheet(isPresented: $showingManualStart) { ManualStartView(model: model).readingMotionAccessibility() }
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let book = model.snapshot.book {
                HStack(alignment: .top, spacing: 12) {
                    BookCoverView(book: book, size: .compact)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title).font(ReadingType.bookTitle(19))
                            .lineLimit(2).accessibilityLabel(book.title)
                        if let author = book.author, !author.isEmpty {
                            Text(author).font(.caption).foregroundStyle(ReadingPalette.ink).lineLimit(1)
                        }
                        ActivityStateLabel(snapshot: model.snapshot, compact: true, onTranslucentSurface: true)
                            .fixedSize(horizontal: false, vertical: true)
                        if let page = model.currentPageText {
                            Text(page).font(.caption).foregroundStyle(ReadingPalette.ink)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed").font(.system(size: 24, weight: .light))
                        .foregroundStyle(ReadingPalette.accent).frame(width: 30, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open a book to begin").font(.callout.weight(.medium))
                        ActivityStateLabel(snapshot: model.snapshot, compact: true, onTranslucentSurface: true)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            MenuReadingGoal(model: model)
            Hairline()
            HStack(alignment: .top, spacing: 20) {
                if model.manualActive || model.snapshot.book != nil || model.sessionPages > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This session").font(.caption).foregroundStyle(ReadingPalette.ink)
                        Text("\(model.sessionPages) \(model.sessionPages == 1 ? "page" : "pages")")
                            .font(ReadingType.numeral(20)).monospacedDigit()
                        Text("\(ReadingFormat.duration(model.snapshot.sessionSeconds)) \(model.manualActive ? "manual" : "recorded")")
                            .font(.caption2).foregroundStyle(ReadingPalette.ink)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(model.dailyGoalStreak.current) \(model.dailyGoalStreak.current == 1 ? "day" : "days")", systemImage: "flame")
                        .font(ReadingType.numeral(20)).monospacedDigit()
                        .foregroundStyle(ReadingPalette.accent)
                    Text(model.dailyGoalStreak.todayPending ? "Goal streak · today still open" : "Goal streak")
                        .font(.caption2).foregroundStyle(ReadingPalette.ink)
                }.frame(maxWidth: .infinity, alignment: .leading)
                .help("Consecutive days that met your daily goal.")
            }
            if let pace = ReadingFormat.pagesPerMinute(model.sessionPagesPerMinute) {
                Label(pace, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption).foregroundStyle(ReadingPalette.ink)
            }
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
                Text(description).font(.caption).foregroundStyle(ReadingPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
    }
}
