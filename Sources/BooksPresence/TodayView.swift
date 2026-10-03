import SwiftUI
import BooksCore

@MainActor
struct TodayView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void

    private var featuredBook: BookRecord? {
        if let book = model.snapshot.book { return book }
        guard let last = model.intervals.first(where: { $0.disposition != .excluded }) else { return nil }
        let id = BookMergeResolver(merges: model.merges).resolvedID(for: last.bookID)
        return model.books.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                PageHeader("Today", subtitle: todaySubtitle) {
                    Label(trackingLabel, systemImage: model.snapshot.phase == .reading ? "book" : "leaf")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ReadingPalette.accent)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(ReadingPalette.accent.opacity(0.10), in: Capsule())
                        .fixedSize()
                }
                // Keep the next reading action above the tall goal summaries,
                // including at the dashboard's minimum window height.
                featuredReading
                if let entry = model.pendingCompletion, model.snapshot.phase != .reading, !model.manualActive {
                    FinishedBookPrompt(model: model, entry: entry)
                }
                ReadingSection("Manual reading") {
                    HStack(spacing: 10) {
                        if model.manualActive {
                            Button("Stop manual reading") { model.stopManual() }
                                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        } else {
                            Button("Read manually") { present(.manualStart) }
                        }
                        Button { present(.manualAdd) } label: { Label("Add time", systemImage: "plus") }
                    }
                    .buttonStyle(ReadingButtonStyle(glass: false))
                    .controlSize(.small)
                }
                DailyReadingOverview(model: model)
                AnnualReadingGoalView(model: model, openBook: { present(.book($0)) })
            }
            .readingPage()
        }
        .buttonStyle(ReadingButtonStyle())
    }

    private var todaySubtitle: String {
        DayParser.date(model.today.day)?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? ReadingFormat.day(model.today.day)
    }

    private var featuredReading: some View {
        ReadingSection(featuredBook == nil ? "Your next read" : (model.snapshot.book == nil ? "Last read" : "Your current read"), accessory: {
            if let book = featuredBook {
                Button("Book details") { present(.book(book)) }.buttonStyle(ReadingButtonStyle(glass: false)).controlSize(.small)
            }
        }) {
            HStack(alignment: .center, spacing: 28) {
                if let book = featuredBook {
                    BookCoverView(book: book, size: .hero)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title).font(ReadingType.bookTitle(30)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let author = book.author, !author.isEmpty {
                            Text(author).font(.body).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        if model.snapshot.book != nil {
                            ActivityStateLabel(snapshot: model.snapshot).padding(.top, 4)
                            HStack(spacing: 28) {
                                LabeledValue(label: "Session pages", value: "\(model.sessionPages)")
                                LabeledValue(label: "Reading time", value: ReadingFormat.duration(model.snapshot.sessionSeconds))
                                if let page = model.currentPageText { LabeledValue(label: "In this book", value: page) }
                            }.padding(.top, 6)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "bookmark")
                                Text("\(model.pages(forBookID: book.id)) pages in your journal")
                            }.font(.callout).foregroundStyle(ReadingPalette.secondaryInk).padding(.top, 2)
                        }
                        readingActions(for: book).padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(ReadingPalette.accent)
                        .frame(width: 96, height: 128)
                        .background(ReadingPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Start reading").font(ReadingType.bookTitle(26))
                        Text("Import an EPUB to read here, or pick up a book from your library.")
                            .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        ReadingGlassGroup {
                            HStack(spacing: 10) {
                                Button { model.epubLibrary.chooseFiles() } label: { Label("Import EPUBs", systemImage: "square.and.arrow.down") }
                                    .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                                Button { model.showDashboard(section: .library) } label: { Label("Browse library", systemImage: "books.vertical") }
                                Button("Open Apple Books") { openBooks() }
                            }
                        }.padding(.top, 5)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Mirrors the Library's read buttons: the in-app reader comes first, Apple Books second.
    @ViewBuilder
    private func readingActions(for book: BookRecord) -> some View {
        let preparing = model.preparingAppleBooksIDs.contains(book.id)
        let inAppleBooks = model.appleBooksAssetID(for: book) != nil
        let readsHere = model.hasEPUB(book) || model.canReadAppleBooksCopy(book) || model.hasImportedEPUB(book)
        ReadingGlassGroup {
            HStack(spacing: 10) {
                if model.hasEPUB(book) {
                    Button { model.readEPUB(book) } label: { Label(model.isOpeningEPUB(book) ? "Opening…" : "Continue reading", systemImage: "book") }
                        .disabled(model.isOpeningEPUB(book))
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                } else if model.canReadAppleBooksCopy(book) {
                    // Books added to Apple Books open here; store purchases stay in Apple Books.
                    Button { model.readFromAppleBooks(book) } label: { Label(preparing ? "Opening…" : "Read in Stillleaf", systemImage: "book") }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary)).disabled(preparing)
                        .help("Open the copy Apple Books keeps of this book. Apple Books is not changed.")
                } else if model.hasImportedEPUB(book) {
                    Button { model.epubLibrary.chooseFiles() } label: { Label("Import to read", systemImage: "square.and.arrow.down") }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                } else if !inAppleBooks {
                    Button { model.showDashboard(section: .library) } label: { Label("Browse library", systemImage: "books.vertical") }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                }
                // A store purchase reads only in Apple Books, so that becomes the main action.
                if inAppleBooks {
                    Button { openBooks() } label: { Label("Open in Apple Books", systemImage: "book") }
                        .buttonStyle(ReadingButtonStyle(emphasis: readsHere ? .secondary : .primary))
                }
            }
        }
    }

    private var trackingLabel: String {
        if !model.trackingEnabled { return "Tracking off" }
        if model.appleBooksTrackingNeedsAccess { return "Apple Books access needed" }
        if model.snapshot.phase == .reading { return "Reading now" }
        return "Ready to read"
    }

    private func openBooks() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") else {
            model.errorMessage = "Apple Books could not be found on this Mac."
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct GoalProgressView: View {
    @ObservedObject var model: AppModel
    let day: DailyTotal
    private var observedPages: Int { model.pages(on: day.day) }
    private var daily: DailyGoalProgress { model.dailyGoal(on: day.day) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Daily goal").font(.callout.weight(.semibold))
                Spacer()
                Text(daily.summary)
                    .font(.callout).monospacedDigit().foregroundStyle(ReadingPalette.fadedInk)
                    .fixedSize()
            }
            if daily.target != nil {
                SegmentedReadingBar(progress: daily.fraction)
                    .frame(height: 8)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: observedPages)
                    .accessibilityLabel("Daily reading goal")
                    .accessibilityValue(daily.summary)
            }
            HStack {
                Text("\(ReadingFormat.duration(day.creditedSeconds)) reading time")
                Spacer()
                if day.manualSeconds > 0 { Text("\(ReadingFormat.duration(day.manualSeconds)) manual") }
            }.font(.caption).foregroundStyle(ReadingPalette.fadedInk)
        }
        .help("Pages include tracked page turns and manual corrections. Time is recorded separately.")
    }
}

struct BookCoverView: View {
    enum Size { case compact, menu, large, library, shelf, shelfLarge, hero, timeline, annual }
    let book: BookRecord?
    let size: Size
    @State private var thumbnail: NSImage?

    private var dimensions: CGSize {
        switch size {
        case .compact: return CGSize(width: 52, height: 72)
        case .menu: return CGSize(width: 62, height: 88)
        case .shelf: return CGSize(width: 108, height: 154)
        case .large: return CGSize(width: 104, height: 148)
        case .library: return CGSize(width: 72, height: 104)
        case .shelfLarge: return CGSize(width: 150, height: 225)
        case .hero: return CGSize(width: 132, height: 198)
        case .timeline: return CGSize(width: 64, height: 96)
        case .annual: return CGSize(width: 92, height: 138)
        }
    }

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    ReadingPalette.parchment
                    HStack(spacing: 0) {
                        Rectangle().fill(ReadingPalette.moss.opacity(0.3)).frame(width: 6)
                        Rectangle().fill(ReadingPalette.ink.opacity(0.08)).frame(width: 1)
                        Spacer()
                    }
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: max(16, dimensions.width * 0.22), weight: .light))
                        if size != .compact && size != .menu && size != .timeline {
                            Text(book?.title ?? "Your next read")
                                .font(.system(size: size == .large || size == .hero || size == .shelfLarge ? 14 : 11, weight: .medium, design: .serif))
                                .multilineTextAlignment(.center).lineLimit(3)
                        }
                    }
                    .foregroundStyle(ReadingPalette.ink.opacity(0.78))
                    .padding(.leading, 7).padding(8)
                }
            }
        }
        .frame(width: dimensions.width, height: dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(ReadingPalette.ink.opacity(0.13)))
        .task(id: book?.coverPath) {
            thumbnail = nil
            guard let path = book?.coverPath else { return }
            let image = await CoverThumbnails.shared.image(at: path)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
        .accessibilityLabel(book?.coverPath == nil ? "Cover unavailable" : "Book cover")
    }
}

struct ActivityStateLabel: View {
    let snapshot: TrackerSnapshot
    var compact = false
    var body: some View {
        let text: String
        let symbol: String
        switch snapshot.phase {
        case .reading: text = "Reading now"; symbol = "record.circle"
        case .uncertain: text = "Time awaiting review"; symbol = "clock.badge.questionmark"
        case .paused: text = "Paused • \(activityPauseSummary(snapshot.pauseReason))"; symbol = "pause.circle"
        }
        return Label(text, systemImage: symbol)
            .font(compact ? .caption : .callout)
            .foregroundStyle(snapshot.phase == .reading ? ReadingPalette.moss : ReadingPalette.fadedInk)
            .accessibilityLabel(snapshot.phase == .paused ? "Tracking paused: \(activityPauseSummary(snapshot.pauseReason))" : text)
    }
}

private func activityPauseSummary(_ reason: PauseReason?) -> String {
    switch reason {
    case .disabled: return "Tracking turned off"
    case .background: return "Reader in background"
    case .noReadingWindow: return "No active reading window"
    case .locked: return "Mac locked"
    case .displayAsleep: return "Display asleep"
    case .permissionLost: return "Apple Books access needed"
    case .excludedBook: return "Book excluded"
    case .stopped: return "Session stopped"
    case .captureFailure: return "Reader needs attention"
    case .recovery: return "Recovering"
    case .clockDiscontinuity: return "Clock changed"
    case nil: return "Waiting for reading"
    }
}

struct UncertainNotice: View {
    let count: Int
    let review: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark").foregroundStyle(ReadingPalette.ochre)
            Text("\(count) interval\(count == 1 ? "" : "s") need review before they count toward your totals.")
            Spacer()
            Button("Review", action: review)
        }
        .font(.callout)
        .padding(14)
        .background(ReadingPalette.ochre.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CompactMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.headline, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

func pauseDescription(_ reason: PauseReason) -> String {
    switch reason {
    case .disabled: return "tracking is disabled"
    case .background: return "the reader is in the background"
    case .noReadingWindow: return "there is no verified reading window"
    case .locked: return "your Mac is locked"
    case .displayAsleep: return "the display is asleep"
    case .permissionLost: return "Apple Books tracking has no Accessibility permission"
    case .excludedBook: return "this book is excluded from tracking"
    case .stopped: return "the session was stopped"
    case .captureFailure: return "capture did not provide a verified reader"
    case .recovery: return "the app recovered after an interruption"
    case .clockDiscontinuity: return "the clock changed unexpectedly"
    }
}
