import SwiftUI
import AppKit
import BooksCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: DashboardSection = .today
    @State private var sheet: DashboardSheet?
    @State private var deleteAllConfirmation = false
    @State private var uninstallConfirmation = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $section, model: model)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage, !error.isEmpty {
                    ErrorBanner(message: error, refresh: { model.refresh() })
                }
                Group {
                    switch section {
                    case .today: TodayView(model: model, present: { sheet = $0 })
                    case .history: HistoryView(model: model)
                    case .library: LibraryView(model: model, present: { sheet = $0 })
                    case .review: ReviewView(model: model, present: { sheet = $0 })
                    case .health: HealthView(model: model)
                    case .settings: SettingsView(model: model, present: { sheet = $0 }, deleteAll: { deleteAllConfirmation = true }, uninstall: { uninstallConfirmation = true })
                    }
                }
            }
            .background(ReadingPalette.paper)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 620)
        .tint(ReadingPalette.moss)
        .sheet(item: $sheet) { item in
            dashboardSheet(item)
        }
        .alert("Delete all reading data?", isPresented: $deleteAllConfirmation) {
            Button("Delete all data", role: .destructive) { model.deleteAllData() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes local reading records, managed backups, and cached covers. Exports and backups you saved elsewhere are not removed; keep those yourself if needed.")
        }
        .alert("Uninstall BooksPresence?", isPresented: $uninstallConfirmation) {
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
            HStack(alignment: .top, spacing: 12) {
                BookCoverView(book: model.snapshot.book, size: .compact)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.snapshot.book?.title ?? "Waiting for a reading window")
                        .font(.system(.headline, design: .serif))
                        .lineLimit(2)
                    if let author = model.snapshot.book?.author, !author.isEmpty {
                        Text(author).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ActivityStateLabel(snapshot: model.snapshot)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                CompactMetric(value: ReadingFormat.duration(model.snapshot.sessionSeconds), label: "session")
                Divider().frame(height: 34)
                CompactMetric(value: ReadingFormat.duration(model.today.creditedSeconds), label: "today")
                Divider().frame(height: 34)
                CompactMetric(value: "\(model.streak.current)", label: "goal streak")
            }

            GoalProgressView(day: model.today)

            if model.manualActive {
                Button("Stop manual reading") { model.stopManual() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Start manual reading") { showingManualStart = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            Toggle("Pause tracking", isOn: trackingBinding)
            Toggle("Share activity with Discord", isOn: $model.discordEnabled)
                .onChange(of: model.discordEnabled) { _ in model.saveSettings() }
            Text(model.discordStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()
            HStack {
                Button("Open dashboard") { model.showDashboard() }
                Spacer()
                Button("Quit") { model.quit() }
            }
        }
        .padding(18)
        .frame(width: 330)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
        .sheet(isPresented: $showingManualStart) { ManualStartView(model: model) }
    }

    private var trackingBinding: Binding<Bool> {
        Binding(get: { !model.trackingEnabled }, set: { paused in
            model.trackingEnabled = !paused
            model.saveSettings()
        })
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
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

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(DashboardSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            Section("Tracking") {
                Toggle("Tracking enabled", isOn: Binding(get: { model.trackingEnabled }, set: { enabled in
                    model.trackingEnabled = enabled
                    model.saveSettings()
                }))
                Toggle("Discord sharing", isOn: Binding(get: { model.discordEnabled }, set: { enabled in
                    model.discordEnabled = enabled
                    model.saveSettings()
                }))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("BooksPresence")
        .frame(minWidth: 190)
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
    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
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
