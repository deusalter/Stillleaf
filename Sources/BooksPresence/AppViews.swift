import SwiftUI
import AppKit
import BooksCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: DashboardSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let initialCalendarScale: CalendarScale
    private let initialSettingsCategory: SettingsCategory

    init(model: AppModel, initialSection: DashboardSection = .today, initialCalendarScale: CalendarScale = .month, initialSettingsCategory: SettingsCategory = .reading) {
        self.model = model
        _section = State(initialValue: initialSection)
        self.initialCalendarScale = initialCalendarScale
        self.initialSettingsCategory = initialSettingsCategory
    }
    @State private var sheet: DashboardSheet?
    @State private var deleteAllConfirmation = false
    @State private var uninstallConfirmation = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $section, model: model)
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
                    case .review: ReviewView(model: model, present: { sheet = $0 })
                    case .health: HealthView(model: model)
                    case .settings: SettingsView(model: model, present: { sheet = $0 }, deleteAll: { deleteAllConfirmation = true }, uninstall: { uninstallConfirmation = true }, initialCategory: initialSettingsCategory)
                    }
                }
                .id(section)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ReadingPalette.paper)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: section)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 920, minHeight: 660)
        .foregroundStyle(ReadingPalette.ink)
        .toggleStyle(.switch)
        .tint(ReadingPalette.moss)
        .buttonStyle(ReadingButtonStyle())
        .sheet(item: $sheet) { item in
            dashboardSheet(item)
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

    @ViewBuilder
    private func dashboardSheet(_ sheet: DashboardSheet) -> some View {
        switch sheet {
        case .manualStart:
            ManualStartView(model: model)
        case .manualAdd:
            ManualAdditionView(model: model)
        case .book(let book):
            BookDetailView(model: model, book: book)
        case .review(let interval):
            IntervalReviewEditor(model: model, interval: interval)
        case .merge(let source):
            MergeBooksView(model: model, source: source)
        case .restore:
            RestoreConfirmationView(model: model)
        }
    }
}

@MainActor
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @State private var showingManualStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Stillleaf", systemImage: "book.closed.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReadingPalette.fadedInk)
                Spacer()
                Button { model.showDashboard() } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Open dashboard")
                    .accessibilityLabel("Open dashboard")
            }
            HStack(alignment: .top, spacing: 14) {
                BookCoverView(book: model.snapshot.book, size: .compact)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.snapshot.book?.title ?? "Ready when you are")
                        .font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(2)
                    if let author = model.snapshot.book?.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ActivityStateLabel(snapshot: model.snapshot)
                    if let page = model.currentPageText {
                        Text(page)
                            .font(.caption)
                            .foregroundStyle(ReadingPalette.fadedInk)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                CompactMetric(value: "\(model.sessionPages)", label: "Session pages")
                CompactMetric(value: "\(model.todayPages)", label: "Today's pages")
                CompactMetric(value: "\(model.pageStreak.current) days", label: "Page-goal streak")
            }
            .padding(.vertical, 10)
            .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            if let pace = ReadingFormat.pagesPerMinute(model.sessionPagesPerMinute) {
                Text("Reading pace: \(pace)")
                    .font(.caption)
                    .foregroundStyle(ReadingPalette.fadedInk)
            }
            GoalProgressView(model: model, day: model.today)
            VStack(spacing: 12) {
                Toggle(isOn: Binding(get: { model.trackingEnabled }, set: { model.trackingEnabled = $0; model.saveSettings() })) {
                    Label("Track reading", systemImage: "timer")
                }
                Toggle(isOn: Binding(get: { model.discordEnabled }, set: { model.discordEnabled = $0; model.saveSettings() })) {
                    Label("Share with Discord", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            if model.automaticTrackingNeedsAccess {
                PopoverSetupNotice(
                    icon: "accessibility",
                    title: "Accessibility access needed",
                    description: "Stillleaf cannot automatically capture reading until macOS grants access."
                ) {
                    Button("Request access") { model.requestAccessibility() }
                        .buttonStyle(ReadingButtonStyle(emphasis: .secondary))
                        .controlSize(.small)
                }
            }
            if model.discordNeedsSetup {
                PopoverSetupNotice(
                    icon: "key.horizontal",
                    title: "Discord needs an Application ID",
                    description: "Add the ID for your Discord application before activity can be shared."
                ) {
                    Link("Open developer portal", destination: URL(string: "https://discord.com/developers/applications")!)
                        .font(.caption)
                }
            }
            HStack {
                Button(model.manualActive ? "Stop manual reading" : "Read manually") {
                    if model.manualActive { model.stopManual() } else { showingManualStart = true }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                Spacer()
                Button("Quit") { model.quit() }.buttonStyle(ReadingButtonStyle(emphasis: .secondary))
            }
        }
        .padding(18)
        .frame(width: 350)
        .foregroundStyle(ReadingPalette.ink)
        .background(ReadingPalette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .tint(ReadingPalette.moss)
        .buttonStyle(ReadingButtonStyle())
        .sheet(isPresented: $showingManualStart) { ManualStartView(model: model) }
    }
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
                .foregroundStyle(ReadingPalette.moss)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(description).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(ReadingPalette.moss.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case today, history, library, review, health, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .history: return "History"
        case .library: return "Library"
        case .review: return "Review"
        case .health: return "Data health"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "text.book.closed"
        case .history: return "calendar"
        case .library: return "books.vertical"
        case .review: return "checklist"
        case .health: return "heart.text.square"
        case .settings: return "gearshape"
        }
    }
}

enum DashboardSheet: Identifiable {
    case manualStart, manualAdd, book(BookRecord), review(ReadingInterval), merge(BookRecord), restore
    var id: String {
        switch self {
        case .manualStart: return "manualStart"
        case .manualAdd: return "manualAdd"
        case .book(let book): return "book-\(book.id)"
        case .review(let interval): return "review-\(interval.id)"
        case .merge(let book): return "merge-\(book.id)"
        case .restore: return "restore"
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardSection
    @ObservedObject var model: AppModel
    @FocusState private var focusedSection: DashboardSection?
    @Namespace private var selectionAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(ReadingPalette.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stillleaf").font(.system(size: 14, weight: .semibold))
                    Text("Your reading journal").font(.system(size: 11)).foregroundStyle(ReadingPalette.fadedInk)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 24)
            VStack(spacing: 5) {
                ForEach(DashboardSection.allCases) { item in
                    Button { selection = item } label: {
                        HStack(spacing: 11) {
                            Image(systemName: item.symbol).font(.system(size: 16, weight: .medium)).frame(width: 22)
                            Text(item.title).font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if item == .review, !model.uncertainIntervals.isEmpty {
                                Text("\(model.uncertainIntervals.count)")
                                    .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(ReadingPalette.ochre.opacity(0.18), in: Capsule())
                            }
                        }
                        .foregroundStyle(selection == item ? ReadingPalette.ink : ReadingPalette.fadedInk)
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(ReadingPalette.moss.opacity(0.14))
                                    .matchedGeometryEffect(id: "sidebar-selection", in: selectionAnimation)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedSection, equals: item)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(focusedSection == item ? ReadingPalette.moss : .clear, lineWidth: 2))
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                    .accessibilityIdentifier("navigation-\(item.rawValue)")
                }
            }
            .padding(.horizontal, 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: selection)
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                      let index = DashboardSection.allCases.firstIndex(of: focusedSection ?? selection) else { return }
                let next = max(0, min(DashboardSection.allCases.count - 1, index + (direction == .down ? 1 : -1)))
                selection = DashboardSection.allCases[next]
                focusedSection = selection
            }
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 14) {
                Button { selection = .health } label: {
                    HStack(spacing: 6) {
                        Circle().fill(model.snapshot.phase == .reading ? ReadingPalette.moss : ReadingPalette.fadedInk).frame(width: 6, height: 6)
                        Text(trackingStatus)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.fadedInk)
                    }
                }
                .buttonStyle(.plain).help("View tracking status")
                Toggle("Track reading", isOn: Binding(get: { model.trackingEnabled }, set: { model.trackingEnabled = $0; model.saveSettings() }))
                Toggle("Discord sharing", isOn: Binding(get: { model.discordEnabled }, set: { model.discordEnabled = $0; model.saveSettings() }))
            }
            .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            .padding(14)
            .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
            Text("History stored on this Mac")
                .font(.system(size: 10)).foregroundStyle(ReadingPalette.fadedInk)
                .frame(maxWidth: .infinity).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingPalette.sidebar)
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
            Text(title).font(.system(.title3, design: .serif))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

enum ReadingPalette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xff) / 255,
                           green: Double((hex >> 8) & 0xff) / 255,
                           blue: Double(hex & 0xff) / 255, alpha: 1)
        })
    }
    static let paper = adaptive(0xE6DADF, 0x241C26)
    static let surface = adaptive(0xF0E7EB, 0x302532)
    static let elevated = adaptive(0xE2D1D9, 0x3D2F3D)
    static let sidebar = adaptive(0xD7C4CE, 0x2A202D)
    static let parchment = adaptive(0xCEB5C1, 0x503B4A)
    static let ink = adaptive(0x352432, 0xF6ECF1)
    static let moss = adaptive(0x8B4F42, 0xE0AE96)
    static let ochre = adaptive(0x606825, 0xC9CE89)
    static let fadedInk = adaptive(0x715A6A, 0xC4ADBD)
    static let border = adaptive(0xC9AEBE, 0x564151)
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
