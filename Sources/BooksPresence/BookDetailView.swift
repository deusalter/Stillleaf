import SwiftUI
import BooksCore

@MainActor
struct BookDetailView: View {
    @ObservedObject var model: AppModel
    let book: BookRecord
    @Environment(\.dismiss) private var dismiss
    @State private var editingInterval: ReadingInterval?
    @State private var deleteBookConfirmation = false
    @State private var completionEntry: FinishedBookEntry?
    @State private var deleteSessionID: String?
    @State private var mergePresented = false
    @State private var showAllSessions = false
    @State private var publicCoverURLDraft = ""
    @State private var editingDates = false

    private var resolver: BookMergeResolver { BookMergeResolver(merges: model.merges) }
    private var currentBook: BookRecord { model.books.first(where: { $0.id == book.id }) ?? book }
    private var relatedBookIDs: Set<String> {
        Set(model.books.filter { resolver.resolvedID(for: $0.id) == book.id }.map(\.id))
    }
    private var sessions: [ReadingInterval] {
        model.displayIntervals.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var sessionGroups: [ReadingSessionGroup] {
        model.visibleReadingSessions.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.start > $1.start }
    }
    private var observations: [ProgressObservation] {
        model.progress.filter { relatedBookIDs.contains($0.bookID) }.sorted { $0.observedAt > $1.observedAt }
    }
    private var credited: Double { sessions.filter { $0.disposition == .credited }.reduce(0) { $0 + $1.duration } }
    private var listeningCredited: Double {
        sessions.filter { $0.disposition == .credited && model.isListening($0) }.reduce(0) { $0 + $1.duration }
    }
    private var observedPages: Int { model.pages(forBookID: currentBook.id) }
    private var pagesPerMinute: Double? { model.pagesPerMinute(forBookID: currentBook.id) }
    private var latestReliableProgress: ProgressObservation? { model.libraryProgressObservations[currentBook.id] }
    private var finishedEntry: FinishedBookEntry? { model.finishedBooks.first { $0.id == currentBook.id } }
    private var ratingText: String? {
        model.rating(for: currentBook.id).map { "\($0.formatted(.number.precision(.fractionLength(0...2)))) / 5" }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                // The sheet is the surface; its sections are told apart by spacing and type.
                VStack(alignment: .leading, spacing: 32) {
                    hero
                    AudiobookSection(model: model, book: currentBook, player: model.audiobookPlayer)
                    readingSummary
                    BookRatingSection(model: model, bookID: currentBook.id)
                    BookReviewSection(model: model, bookID: currentBook.id)
                    sessionHistory
                    privacyControls
                    DisclosureGroup("Cover art & sharing details") { artworkControls.padding(.top, 8) }
                        .font(.callout).padding(.horizontal, 4)
                    advancedSection
                    footerActions
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 760, height: 720)
        .readingSheetSurface()
        .background(ReadingPalette.canvas)
        .tint(ReadingPalette.accent)
        .foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .sheet(item: $completionEntry) { CompletionReviewSheet(model: model, entry: $0).readingMotionAccessibility() }
        .sheet(item: $editingInterval) { ReadingSessionEditor(model: model, interval: $0) }
        .sheet(isPresented: $mergePresented) { MergeBooksView(model: model, source: currentBook) }
        .sheet(isPresented: $editingDates) {
            if let entry = finishedEntry {
                ReadingDatesEditor(title: entry.title,
                    dates: ReadingCompletionDates(startedAt: entry.startedAt, finishedAt: entry.finishedAt),
                    timezoneID: model.timezoneID) { dates in model.saveReadingDates(dates, for: entry.id) }
            }
        }
        .onAppear { publicCoverURLDraft = model.publicCoverURL(for: currentBook) }
        .alert("Delete \(currentBook.title)?", isPresented: $deleteBookConfirmation) {
            Button("Delete book", role: .destructive) { model.deleteBook(currentBook); dismiss() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes its Stillleaf history, rating and review, and clears managed backups. The original Apple Books file and exports saved elsewhere remain.")
        }
        .alert("Delete this session?", isPresented: Binding(get: { deleteSessionID != nil }, set: { if !$0 { deleteSessionID = nil } })) {
            Button("Delete session", role: .destructive) {
                if let deleteSessionID { model.deleteSession(deleteSessionID) }
                deleteSessionID = nil
            }
            Button("Cancel", role: .cancel) { deleteSessionID = nil }
        } message: {
            Text("This permanently removes this session and its related correction records.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Book details").font(ReadingType.bookTitle(19))
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(ReadingButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 24) {
            BookCoverView(book: currentBook, size: .hero)
            VStack(alignment: .leading, spacing: 7) {
                Text(currentBook.title)
                    .font(ReadingType.bookTitle(30))
                    .foregroundStyle(ReadingPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(currentBook.author?.isEmpty == false ? currentBook.author! : "Author unavailable")
                    .font(.callout)
                    .foregroundStyle(ReadingPalette.secondaryInk)
                if let finishedEntry {
                    HStack(spacing: 10) {
                        Label(finishedEntry.finishedAt.map { "Finished \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Marked finished", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(ReadingPalette.accent)
                        Button("Edit reading dates") { editingDates = true }
                            .controlSize(.small)
                            .accessibilityHint("Change when you started and finished this book")
                    }.padding(.top, 4)
                }
                if finishedEntry == nil {
                    Button { completionEntry = model.markFinished(currentBook) } label: { Label("Mark as finished", systemImage: "checkmark.circle") }
                        .controlSize(.small).buttonStyle(ReadingButtonStyle(emphasis: .primary))
                }
                if let ratingText {
                    Label("Your rating: \(ratingText)", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(ReadingPalette.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var readingSummary: some View {
        ReadingSection("Reading at a glance") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    if currentBook.resolvedFormat != .audiobook {
                        StatLine(value: "\(observedPages)", label: "Pages")
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                    }
                    StatLine(value: ReadingFormat.duration(currentBook.resolvedFormat == .audiobook ? listeningCredited : credited), label: currentBook.resolvedFormat == .audiobook ? "Listening time" : "Reading time")
                    if currentBook.resolvedFormat == .audiobook && credited > listeningCredited {
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                        StatLine(value: ReadingFormat.duration(credited - listeningCredited), label: "Other reading time")
                    }
                    if currentBook.resolvedFormat != .audiobook {
                        Hairline(axis: .vertical).frame(height: 44).padding(.horizontal, 18)
                        StatLine(value: ReadingFormat.pagesPerMinute(pagesPerMinute) ?? "Building pace", label: "Pace")
                    }
                }
                let corrected = model.manualPages(forBookID: currentBook.id)
                if corrected > 0 {
                    Text("Includes \(corrected) manually added pages. Pace uses automatic observations only.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var sessionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session history").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
                }
                Spacer()
                Text("\(sessionGroups.count) \(sessionGroups.count == 1 ? "session" : "sessions")")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            if sessionGroups.isEmpty {
                Text("No sessions have been recorded for this book.").foregroundStyle(ReadingPalette.secondaryInk)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(showAllSessions ? sessionGroups : Array(sessionGroups.prefix(5))) { group in
                        BookDetailSessionGroup(
                            group: group,
                            pages: model.pages(in: group),
                            audio: model.audiobookProgress(in: group),
                            isAudiobook: group.intervals.contains { model.isListening($0) },
                            editSession: { editingInterval = $0 },
                            delete: { deleteSessionID = $0 }
                        )
                    }
                    if sessionGroups.count > 5 {
                        Button(showAllSessions ? "Show recent sessions" : "Show all \(sessionGroups.count) sessions") { showAllSessions.toggle() }
                            .buttonStyle(ReadingButtonStyle())
                    }
                }
            }
        }
        .readingPanel()
    }

    private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This book").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
            BookDetailToggleRow(title: "Track reading", message: "Include new reading evidence in your journal.", isOn: trackingBinding)
            Divider()
            BookDetailToggleRow(title: "Share with Discord", message: "Allow this title on your Discord card when sharing is on.", isOn: sharingBinding)
            Text("Changing either setting keeps existing history.")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
        .readingPanel()
    }

    private var artworkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discord artwork").font(ReadingType.bookTitle(19)).foregroundStyle(ReadingPalette.ink)
                    Text(artworkStatus).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
                Spacer()
                Image(systemName: model.publicCoverURL(for: currentBook).isEmpty ? "photo.on.rectangle.angled" : "checkmark.seal.fill")
                    .foregroundStyle(model.publicCoverURL(for: currentBook).isEmpty ? ReadingPalette.secondaryInk : ReadingPalette.accent)
            }
            if currentBook.source != "stillleaf-epub" {
            DisclosureGroup("Use a different public cover link") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Public HTTPS image URL", text: $publicCoverURLDraft)
                        .textFieldStyle(ReadingTextFieldStyle())
                        .onSubmit { savePublicCoverURL() }
                    HStack {
                        Button("Save public link") { savePublicCoverURL() }
                            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        Spacer()
                        if !publicCoverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Remove link") { publicCoverURLDraft = ""; savePublicCoverURL() }
                                .controlSize(.small)
                                .buttonStyle(ReadingButtonStyle())
                        }
                    }
                }
                .padding(.top, 7)
            }
            } else {
                Text("Reading here uses local cover art only. Discord uses the app's generic artwork; your EPUB cover is never uploaded.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            DisclosureGroup("Local cover override") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("This changes the cover saved on this Mac. It is never uploaded or sent to Discord.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    Button("Choose local cover image") { model.chooseCover(for: currentBook) }
                        .buttonStyle(ReadingButtonStyle())
                }
                .padding(.top, 7)
            }
        }
        .readingPanel()
    }

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let latestReliableProgress {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(ReadingPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Latest reliable progress").font(.callout.weight(.medium))
                            ProgressDescription(observation: latestReliableProgress)
                            Text(ReadingFormat.date(latestReliableProgress.observedAt)).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }
                } else {
                    Text("No reliable saved progress is available for this book.")
                        .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }
                Divider()
                HStack {
                    Text("Book management").font(.callout.weight(.medium))
                    Spacer()
                    Button("Merge with another book") { mergePresented = true }
                        .controlSize(.small)
                        .buttonStyle(ReadingButtonStyle())
                }
                ForEach(activeMerges) { merge in
                    HStack {
                        Text("Merged with \(otherBookName(merge))").font(.caption)
                        Spacer()
                        Button("Unmerge") { model.unmerge(merge) }.controlSize(.small).buttonStyle(ReadingButtonStyle())
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced and metadata", systemImage: "slider.horizontal.3")
                .foregroundStyle(ReadingPalette.ink)
        }
        .readingPanel()
    }

    private var footerActions: some View {
        HStack {
            Spacer()
            if activeMerges.isEmpty {
                Button("Delete book", role: .destructive) { deleteBookConfirmation = true }
                    .buttonStyle(ReadingButtonStyle())
            }
        }
        .padding(.top, 2)
    }

    private var artworkStatus: String {
        if !model.publicCoverURL(for: currentBook).isEmpty { return "Using a saved public cover link for this card." }
        if model.automaticPublicCovers { return "Automatic public-cover lookup is on. A unique Apple metadata match can add a public link." }
        return "Using your app’s generic artwork when configured. Automatic public-cover lookup is off."
    }

    private var trackingBinding: Binding<Bool> {
        Binding(get: { !currentBook.trackingExcluded }, set: { enabled in
            let current = self.currentBook
            model.setBookExclusions(current, tracking: !enabled, sharing: current.sharingExcluded)
        })
    }

    private var sharingBinding: Binding<Bool> {
        Binding(get: { !currentBook.sharingExcluded }, set: { enabled in
            let current = self.currentBook
            model.setBookExclusions(current, tracking: current.trackingExcluded, sharing: !enabled)
        })
    }

    private var activeMerges: [BookMerge] {
        resolver.activeMerges.filter { $0.sourceID == book.id || $0.targetID == book.id }
    }

    private func otherBookName(_ merge: BookMerge) -> String {
        let identifier = merge.sourceID == book.id ? merge.targetID : merge.sourceID
        return model.books.first(where: { $0.id == identifier })?.title ?? "a deleted book"
    }

    private func savePublicCoverURL() {
        model.savePublicCoverURL(publicCoverURLDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: currentBook)
        publicCoverURLDraft = model.publicCoverURL(for: currentBook)
    }
}

private struct BookDetailToggleRow: View {
    let title: String
    let message: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.ink)
                Text(message).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookDetailSessionGroup: View {
    let group: ReadingSessionGroup
    let pages: Int
    let audio: AudiobookProgress?
    let isAudiobook: Bool
    let editSession: (ReadingInterval) -> Void
    let delete: (String) -> Void

    var body: some View {
        DisclosureGroup {
            LazyVStack(spacing: 0) {
                ForEach(group.intervals) { interval in
                    BookDetailSessionFragment(
                        interval: interval,
                        editSession: { editSession(interval) },
                        delete: { delete(interval.sessionID) }
                    )
                    if interval.id != (group.intervals.last?.id ?? "") { Divider() }
                }
            }
            .padding(.top, 7)
            .buttonStyle(ReadingButtonStyle())
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ReadingFormat.date(group.start)).font(.callout.weight(.semibold)).foregroundStyle(ReadingPalette.ink)
                    Text(group.creditedSeconds == 0 && pages > 0 ? "Pages added manually" : "Credited \(ReadingFormat.duration(group.creditedSeconds))")
                        .font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
                }
                Spacer()
                Text(audio.map { "\($0.fraction.formatted(.percent.precision(.fractionLength(0...1)))) · \($0.description)" } ?? (isAudiobook ? "Listening" : ReadingFormat.observedPages(pages)))
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(ReadingPalette.accent)
            }
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 10)
        .background(ReadingPalette.canvas.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct BookDetailSessionFragment: View {
    let interval: ReadingInterval
    let editSession: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ReadingFormat.date(interval.start)).font(.callout.weight(.medium))
                Text("\(interval.mode.rawValue.capitalized) · \(interval.disposition.rawValue)")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer()
            Text(ReadingFormat.duration(interval.duration))
                .font(.caption).monospacedDigit().foregroundStyle(ReadingPalette.secondaryInk)
            Button("Edit", action: editSession).controlSize(.small)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .accessibilityLabel("Delete session")
        }
        .padding(.vertical, 6)
    }
}

struct ProgressDescription: View {
    let observation: ProgressObservation
    var body: some View {
        Group {
            if let audio = observation.audio {
                Text("\(audio.fraction.formatted(.percent.precision(.fractionLength(0...1)))) · \(audio.description)")
            } else if observation.reliable, let fraction = observation.fraction {
                Text("Progress \(Int((fraction * 100).rounded()))%")
            } else if observation.reliable, let page = observation.page, let total = observation.totalPages {
                Text("Page \(page) of \(total)")
            } else if let location = observation.location, !location.isEmpty {
                Text("Observed location: \(location)")
            } else {
                Text("Progress observation is not reliable")
            }
        }
        .font(.callout)
        .foregroundStyle(observation.reliable ? ReadingPalette.accent : ReadingPalette.secondaryInk)
    }
}
