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
                // One surface holds the whole day; its parts are grouped by spacing and type.
                // The next reading action stays above the tall goal summaries, including at
                // the dashboard's minimum window height.
                VStack(alignment: .leading, spacing: 40) {
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
                .readingPanel()
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
                        if let fraction = bookFraction(book) {
                            DottedProgressRow(fraction: fraction).frame(maxWidth: 360).padding(.top, 6)
                        }
                        if model.snapshot.book != nil {
                            ActivityStateLabel(snapshot: model.snapshot).padding(.top, 4)
                            HStack(spacing: 28) {
                                LabeledValue(label: "Session pages", value: "\(model.sessionPages)", countKey: "today.session.pages")
                                LabeledValue(label: "Reading time", value: ReadingFormat.duration(model.snapshot.sessionSeconds), countKey: "today.session.time")
                                if let page = model.currentPageText { LabeledValue(label: "In this book", value: page, countKey: "today.session.page") }
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

    /// How far through the book the latest reliable position is, if known.
    private func bookFraction(_ book: BookRecord) -> Double? {
        guard let observation = model.libraryProgressObservations[book.id] else { return nil }
        if let page = observation.page, let total = observation.totalPages, total > 0 { return min(1, Double(page) / Double(total)) }
        return observation.fraction.map { min(1, max(0, $0)) }
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

struct ActivityStateLabel: View {
    let snapshot: TrackerSnapshot
    var compact = false
    var onTranslucentSurface = false
    var body: some View {
        let text: String
        let symbol: String
        switch snapshot.phase {
        case .reading: text = "Reading now"; symbol = "record.circle"
        case .paused: text = "Paused • \(activityPauseSummary(snapshot.pauseReason))"; symbol = "pause.circle"
        }
        return Label(text, systemImage: symbol)
            .font(compact ? .caption : .callout)
            .foregroundStyle(onTranslucentSurface ? ReadingPalette.ink : (snapshot.phase == .reading ? ReadingPalette.accent : ReadingPalette.secondaryInk))
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

struct LabeledValue: View {
    let label: String
    let value: String
    /// Names the number so it counts up when it first appears; `nil` for plain text.
    var countKey: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            if let countKey {
                CountingText(value, key: countKey).font(.callout).monospacedDigit()
            } else {
                Text(value).font(.callout).monospacedDigit()
            }
        }
    }
}
