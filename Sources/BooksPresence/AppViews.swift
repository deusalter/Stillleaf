import SwiftUI
import AppKit
import BooksCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: DashboardSection
    private let initialCalendarScale: CalendarScale
    private let initialSettingsCategory: SettingsCategory

    init(model: AppModel, initialSection: DashboardSection = .today, initialCalendarScale: CalendarScale = .month, initialSettingsCategory: SettingsCategory = .reading) {
        self.model = model
        _section = State(initialValue: initialSection)
        self.initialCalendarScale = initialCalendarScale
        self.initialSettingsCategory = initialSettingsCategory
    }
    @State private var sheet: DashboardSheet?
    @ObservedObject private var theme = ThemeStore.shared
    @State private var deleteAllConfirmation = false
    @State private var uninstallConfirmation = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $section, model: model, troubleshoot: { sheet = .trackingHelp })
                .id(theme.revision)
                .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage, !error.isEmpty {
                    ErrorBanner(message: error, refresh: { model.refresh() })
                }
                Group {
                    switch section {
                    case .today: TodayView(model: model, present: { sheet = $0 })
                    case .history: HistoryView(model: model, initialScale: initialCalendarScale)
                    case .library: LibraryView(model: model, present: { sheet = $0 })
                    case .review: PersonalReviewsView(model: model)
                    case .timeline: ReadingTimelineView(model: model, present: { sheet = $0 })
                    case .health: HealthView(model: model)
                    case .settings: SettingsView(model: model, present: { sheet = $0 }, deleteAll: { deleteAllConfirmation = true }, uninstall: { uninstallConfirmation = true }, initialCategory: model.settingsCategoryRequest ?? initialSettingsCategory)
                        .id(model.settingsCategoryRequest)
                    }
                }
                // A theme change re-keys only the rendered content, inside the entrance, so it
                // swaps instantly instead of replaying the fade. Settings owns unsaved drafts
                // and re-keys its own content instead.
                .id(Self.contentKey(for: section, revision: theme.revision))
                .readingEntrance()
                .id(section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ReadingPalette.paper)
        }
        .readingMotionAccessibility()
        .onAppear { acceptNavigationRequest() }
        .onChange(of: model.dashboardSectionRequest) { _ in acceptNavigationRequest() }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 660)
        .foregroundStyle(ReadingPalette.ink)
        .toggleStyle(.switch)
        .tint(ReadingPalette.moss)
        .buttonStyle(ReadingButtonStyle())
        .sheet(item: $sheet) { item in
            dashboardSheet(item).readingMotionAccessibility()
        }
        .alert("Delete all reading data?", isPresented: $deleteAllConfirmation) {
            Button("Delete all data", role: .destructive) { model.deleteAllData() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes local reading records, managed backups, and cached covers. Exports and backups you saved elsewhere are not removed; keep those yourself if needed.")
        }
        .alert("Uninstall Stillleaf?", isPresented: $uninstallConfirmation) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This disables startup and moves the installed app to Trash. Your local reading history remains. Use Delete all reading data to remove managed history, backups, and cached covers.")
        }
    }

    /// Identity of the rendered screen for a theme revision. Settings keeps one identity
    /// because it owns unsaved drafts; every other screen re-keys so colours re-resolve.
    static func contentKey(for section: DashboardSection, revision: Int) -> String {
        section == .settings ? "settings" : "content-\(revision)"
    }

    private func acceptNavigationRequest() {
        guard let requested = model.dashboardSectionRequest else { return }
        section = requested
        model.dashboardSectionRequest = nil
    }

    @ViewBuilder
    private func dashboardSheet(_ sheet: DashboardSheet) -> some View {
        switch sheet {
        case .manualStart:
            ManualStartView(model: model)
        case .manualAdd:
            ManualAdditionView(model: model)
        case .completion(let entry):
            CompletionReviewSheet(model: model, entry: entry)
        case .book(let book):
            BookDetailView(model: model, book: book)
        case .review(let interval):
            IntervalReviewEditor(model: model, interval: interval)
        case .merge(let source):
            MergeBooksView(model: model, source: source)
        case .restore:
            RestoreConfirmationView(model: model)
        case .trackingHelp:
            TrackingHelpView(model: model)
        }
    }
}

@MainActor
struct PopoverView: View {
    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 640
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showingManualStart = false
    @State private var bodyHeight: CGFloat = 390

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                PageleafMark().frame(width: 18, height: 18).foregroundStyle(ReadingPalette.accent)
                Text("Stillleaf").font(.system(size: 16, weight: .regular, design: .serif))
                    .accessibilityLabel("Stillleaf")
                Spacer()
                Button { model.showDashboard() } label: {
                    Label("Dashboard", systemImage: "arrow.up.forward.app")
                }.controlSize(.small).accessibilityLabel("Open dashboard")
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
                    .font(.caption2).foregroundStyle(ReadingPalette.secondaryInk)
                    .frame(maxWidth: .infinity)
            }
            Hairline()
            HStack {
                Button(model.manualActive ? "Stop manual reading" : "Read manually") {
                    if model.manualActive { model.stopManual() } else { showingManualStart = true }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: model.manualActive ? .primary : .secondary)).controlSize(.small)
                Spacer()
                Button("Settings") { model.showDashboard(section: .settings) }.controlSize(.small)
                Menu {
                    Button("Quit Stillleaf") { model.quit() }
                } label: { Image(systemName: "ellipsis").frame(width: 12, height: 18) }
                .menuStyle(ReadingMenuStyle()).menuIndicator(.hidden)
                .accessibilityLabel("More actions")
            }
        }
        .id(theme.revision)
        .padding(18).frame(width: 350)
        .foregroundStyle(ReadingPalette.ink)
        .background(ReadingPalette.canvas, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(ReadingPalette.moss).buttonStyle(ReadingButtonStyle())
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
                            Text(author).font(.caption).foregroundStyle(ReadingPalette.fadedInk).lineLimit(1)
                        }
                        ActivityStateLabel(snapshot: model.snapshot, compact: true)
                            .fixedSize(horizontal: false, vertical: true)
                        if let page = model.currentPageText {
                            Text(page).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "book.closed").font(.system(size: 20, weight: .light))
                        .foregroundStyle(ReadingPalette.accent).frame(width: 36, height: 42)
                        .background(ReadingPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Open a book to begin").font(ReadingType.bookTitle(18))
                        ActivityStateLabel(snapshot: model.snapshot, compact: true)
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
                        Text("This session").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        Text("\(model.sessionPages) \(model.sessionPages == 1 ? "page" : "pages")")
                            .font(ReadingType.numeral(20)).monospacedDigit()
                        Text("\(ReadingFormat.duration(model.snapshot.sessionSeconds)) \(model.manualActive ? "manual" : "recorded")")
                            .font(.caption2).foregroundStyle(ReadingPalette.fadedInk)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(model.dailyGoalStreak.current) \(model.dailyGoalStreak.current == 1 ? "day" : "days")", systemImage: "flame")
                        .font(ReadingType.numeral(20)).monospacedDigit()
                        .foregroundStyle(ReadingPalette.accent)
                    Text(model.dailyGoalStreak.todayPending ? "Goal streak · today still open" : "Goal streak")
                        .font(.caption2).foregroundStyle(ReadingPalette.fadedInk)
                }.frame(maxWidth: .infinity, alignment: .leading)
                .help(model.dailyGoalStreak.provisional ? "This streak is provisional until pending time is reviewed." : "Consecutive days that met your daily goal.")
            }
            if let pace = ReadingFormat.pagesPerMinute(model.sessionPagesPerMinute) {
                Label(pace, systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            if model.automaticTrackingNeedsAccess {
                PopoverSetupNotice(icon: "accessibility", title: "Allow automatic tracking",
                    description: "Stillleaf needs Accessibility access.") {
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
                Text(description).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case today, history, library, timeline, review, health, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .history: return "History"
        case .library: return "Library"
        case .review: return "Reviews"
        case .timeline: return "Timeline"
        case .health: return "Data health"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "text.book.closed"
        case .history: return "calendar"
        case .library: return "books.vertical"
        case .review: return "square.and.pencil"
        case .timeline: return "clock"
        case .health: return "heart.text.square"
        case .settings: return "gearshape"
        }
    }
}

enum DashboardSheet: Identifiable {
    case manualStart, manualAdd, completion(FinishedBookEntry), book(BookRecord), review(ReadingInterval), merge(BookRecord), restore, trackingHelp
    var id: String {
        switch self {
        case .manualStart: return "manualStart"
        case .manualAdd: return "manualAdd"
        case .completion(let entry): return "completion-\(entry.id)"
        case .book(let book): return "book-\(book.id)"
        case .review(let interval): return "review-\(interval.id)"
        case .merge(let book): return "merge-\(book.id)"
        case .restore: return "restore"
        case .trackingHelp: return "trackingHelp"
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardSection
    @ObservedObject var model: AppModel
    let troubleshoot: () -> Void
    private let destinations: [DashboardSection] = [.today, .library, .timeline, .history, .review, .settings]
    @FocusState private var focusedSection: DashboardSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                PageleafMark()
                    .frame(width: 23, height: 23)
                    .foregroundStyle(ReadingPalette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stillleaf").font(.system(size: 21, weight: .regular, design: .serif)).tracking(-0.3)
                }
            }
            .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 26)
            VStack(spacing: 2) {
                ForEach(destinations) { item in
                    Button { selection = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).font(.system(size: 14, weight: .regular)).frame(width: 20)
                                .foregroundStyle(selection == item ? ReadingPalette.accent : ReadingPalette.secondaryInk)
                            Text(item.title).font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(selection == item ? ReadingPalette.ink : ReadingPalette.secondaryInk)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ReadingPalette.accent.opacity(0.12))
                                    .transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection == item)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedSection, equals: item)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focusedSection == item ? ReadingPalette.accent : .clear, lineWidth: 2))
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                    .accessibilityIdentifier("navigation-\(item.rawValue)")
                }
            }
            .padding(.horizontal, 10)
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                      let index = destinations.firstIndex(of: focusedSection ?? selection) else { return }
                let next = max(0, min(destinations.count - 1, index + (direction == .down ? 1 : -1)))
                selection = destinations[next]
                focusedSection = selection
            }
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 6) {
                if model.automaticTrackingNeedsAccess || model.snapshot.pauseReason == .captureFailure {
                    Button(action: troubleshoot) {
                        Label(trackingStatus, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.warning)
                    }.buttonStyle(.plain).help("Open tracking help")
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(model.snapshot.phase == .reading ? ReadingPalette.accent : ReadingPalette.secondaryInk).frame(width: 6, height: 6)
                        Text(trackingStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
                Text("History stored on this Mac")
                    .font(.system(size: 10)).foregroundStyle(ReadingPalette.secondaryInk)
            }
            .padding(.horizontal, 20).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ReadingPalette.ink)
        .background(ReadingPalette.canvas)
        .overlay(alignment: .trailing) { Hairline(axis: .vertical) }
    }

    private var trackingStatus: String {
        if !model.trackingEnabled { return "Tracking paused" }
        if model.snapshot.phase == .reading { return "Reading now" }
        if model.snapshot.phase == .uncertain { return "Review suggested" }
        switch model.snapshot.pauseReason {
        case .permissionLost: return "Access needed"
        case .background: return "Waiting for Books"
        case .locked, .displayAsleep: return "Tracking paused"
        case .captureFailure: return "Check tracking status"
        default: return "Waiting for a book"
        }
    }
}

@MainActor
private struct ErrorBanner: View {
    let message: String
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(2)
            Spacer()
            Button("Try again", action: refresh)
        }
        .font(.callout)
        .foregroundStyle(ReadingPalette.ink)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(ReadingPalette.ochre.opacity(0.26))
    }
}

struct ReadingEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(ReadingPalette.fadedInk)
            Text(title).font(ReadingType.bookTitle(20))
            Text(message).font(.callout).foregroundStyle(ReadingPalette.secondaryInk).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

enum ReadingFormat {
    static func observedPages(_ value: Int) -> String {
        "\(value) observed \(value == 1 ? "page" : "pages")"
    }

    static func pagePace(_ minutesPerPage: Double?) -> String? {
        guard let minutesPerPage, minutesPerPage.isFinite, minutesPerPage > 0 else { return nil }
        if minutesPerPage < 1 {
            return "\(max(1, Int((60 / minutesPerPage).rounded()))) pages/hour"
        }
        return "\(minutesPerPage.formatted(.number.precision(.fractionLength(1)))) min/page"
    }

    static func pagesPerMinute(_ value: Double?) -> String? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return "\(value.formatted(.number.precision(.fractionLength(2)))) pages/min"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if rounded < 60 { return "\(rounded)s" }
        return "\(minutes)m"
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "Not yet recorded" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ string: String) -> String {
        guard let date = DayParser.date(string) else { return string }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

enum DayParser {
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
