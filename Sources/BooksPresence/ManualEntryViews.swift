import SwiftUI
import BooksCore
import BooksPlatform

@MainActor
struct ManualStartView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReadingSheetHeader(title: "Read manually", subtitle: "Track time with a paper book or another reader.", close: { dismiss() })
            VStack(spacing: 12) {
                TextField("Book title", text: $title)
                TextField("Author (optional)", text: $author)
            }.readingPanel()
            Text("Saved as manual reading time. Pages are not estimated.")
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(ReadingPalette.warning) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start reading") {
                    if model.startManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        dismiss()
                    } else { saveError = model.errorMessage ?? "Could not start reading. Try again." }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 470)
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent).textFieldStyle(ReadingTextFieldStyle())
        .buttonStyle(ReadingButtonStyle())
    }
}

/// "Add reading time": log time, pages or both for a book, or listening for an audiobook.
@MainActor
struct ManualAdditionView: View {
    /// Starting state for previews and tests; the real sheet always opens empty.
    struct Preview {
        var query = ""
        var choice: ManualBookChoice?
        var typedAuthor = ""
        var draft = ManualEntryDraft()
        var searchPhase: BookSearchController.Phase = .idle
    }

    @ObservedObject var model: AppModel
    var maximumHeight: CGFloat = 700
    private let service: BookSearchService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var search: BookSearchController
    @State private var draft: ManualEntryDraft
    @State private var query: String
    @State private var choice: ManualBookChoice?
    @State private var typedAuthor: String
    @State private var pickedDate = Date()
    @State private var showingCalendar = false
    @State private var saving = false
    @State private var saveError: String?

    init(model: AppModel, service: BookSearchService = OpenLibraryClient(), preview: Preview = Preview(), maximumHeight: CGFloat = 700) {
        self.model = model
        self.service = service
        self.maximumHeight = maximumHeight
        _search = StateObject(wrappedValue: BookSearchController(service: service, initialPhase: preview.searchPhase))
        _draft = State(initialValue: preview.draft)
        _query = State(initialValue: preview.query)
        _choice = State(initialValue: preview.choice)
        _typedAuthor = State(initialValue: preview.typedAuthor)
    }

    private var zone: TimeZone { TimeZone(identifier: model.timezoneID) ?? .current }
    private var library: [BookRecord] { model.books.filter { model.canonicalLibraryBook($0)?.id == $0.id } }

    // MARK: Chosen book

    /// The record this entry will be saved against, and whether it is new to the library.
    private var chosenBook: (record: BookRecord, isNew: Bool)? {
        switch choice {
        case nil: return nil
        case let .library(book)?: return (book, false)
        case let .outside(book)?:
            if let existing = library.first(where: { $0.id == book.libraryID }) { return (existing, false) }
            return (BookRecord(id: book.libraryID, title: book.title, author: book.author, source: "Open Library", pageCount: book.pageCount), true)
        case let .typed(title)?:
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let author = typedAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
            return (BookRecord(id: "manual:\(UUID().uuidString)", title: name, author: author.isEmpty ? nil : author), true)
        }
    }

    private var totalPages: Int? {
        switch choice {
        case let .library(book)?: return model.totalPages(for: book)
        case let .outside(book)?: return library.first { $0.id == book.libraryID }.flatMap { model.totalPages(for: $0) } ?? book.pageCount
        default: return nil
        }
    }

    private var issue: ManualDraftIssue? {
        guard let choice else { return .chooseBook }
        if case let .typed(title) = choice, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .needsTitle }
        let existing = model.intervals.filter { $0.disposition != .excluded }
        if draft.kind == .audiobook, let audio = draft.audio().issue { return audio }
        guard draft.includesTime || draft.includesPages else { return nil }
        return draft.entry(bookID: "pending", totalPages: totalPages, existing: existing, now: Date(), zone: zone).issue
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReadingSheetHeader(title: "Add reading time", subtitle: nil, close: { dismiss() })
            GlassSegmentedControl(label: "What are you logging?", options: ManualEntryKind.allCases,
                                  selection: $draft.kind, title: { $0.rawValue },
                                  systemImage: { $0 == .book ? "book" : "headphones" },
                                  style: .navigation, onGlass: true)
                .onChange(of: draft.kind) { _ in switchKind() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ManualBookPicker(kind: draft.kind, library: library, query: $query, choice: $choice,
                                     typedAuthor: $typedAuthor, search: search, service: service)
                    if draft.kind == .book { bookForm.transition(formTransition) }
                    else { audiobookForm.transition(formTransition) }
                }
                .padding(2)
            }
            .scrollIndicators(.visible)
            Hairline()
            footer
        }
        .padding(26)
        .frame(width: 540, height: min(maximumHeight, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent).textFieldStyle(GlassTextFieldStyle())
        .buttonStyle(ReadingButtonStyle())
        .onChange(of: choice) { _ in saveError = nil; trimPagesStyle() }
        .onChange(of: draft) { _ in saveError = nil }
    }

    private var formTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }

    private func switchKind() {
        // A book only fits one mode: an audiobook can't take pages, and a text book can't take a listening position.
        if let current = choice, case let .library(book) = current,
           (draft.kind == .book) != (book.resolvedFormat == .text) { choice = nil }
        if case .outside? = choice, draft.kind == .audiobook { choice = nil }
        search.cancel()
        if draft.kind == .book { search.update(query: query) }
    }

    /// A from–to range needs the book's page count; without it only a plain count makes sense.
    private func trimPagesStyle() {
        if totalPages == nil, draft.pagesStyle == .range { draft.pagesStyle = .count }
    }

    // MARK: Book form

    private var bookForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("What did you read?").font(.headline)
                GlassSegmentedControl(label: "What did you read?", options: ManualContent.allCases,
                                      selection: $draft.content, title: { $0.rawValue })
                if draft.includesTime { lengthControls }
                if draft.includesPages { pageControls }
                Text(bookNote).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }.readingPanel()
            whenCard
        }
    }

    private var bookNote: String {
        switch draft.content {
        case .time: return "Saved as manual time toward your time goal. It adds no pages or Apple Books activity."
        case .pages: return "Pages count toward your page goal the same way tracked pages do, with no time credited."
        case .both: return "Time counts toward your time goal and pages toward your page goal. Reading pace uses tracked pages only."
        }
    }

    private var lengthControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.kind == .book ? "How long?" : "How long did you listen?")
                .font(.subheadline.weight(.semibold)).foregroundStyle(ReadingPalette.secondaryInk)
            if draft.usesStartTime {
                let length = draft.seconds(now: Date(), zone: zone)
                Text(length.issue == nil ? "\(ManualEntryDraft.durationText(length.value)), from your start and finish times"
                     : "Set a start that comes before the finish")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            } else {
                HStack(spacing: 8) {
                    ForEach(DurationPreset.allCases, id: \.self) { preset in
                        ManualChip(title: preset.label, isSelected: draft.preset == preset) { draft.preset = preset }
                    }
                }
                if draft.preset == .custom { customLength }
            }
        }
    }

    private var customLength: some View {
        HStack(spacing: 10) {
            ManualStepper(decrementLabel: "Five minutes shorter", incrementLabel: "Five minutes longer",
                         decrement: { nudgeCustom(by: -5) }, increment: { nudgeCustom(by: 5) }) {
                TextField("1h 20m", text: $draft.customDuration).textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .accessibilityLabel("Custom length")
            }.frame(width: 190)
            Text("Try 45, 1h 20m or 1:30").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
        }
    }

    private func nudgeCustom(by minutes: Int) {
        let current = ManualEntryParsing.duration(draft.customDuration) ?? 0
        let next = max(5 * 60, current + TimeInterval(minutes) * 60)
        draft.customDuration = ManualEntryDraft.compactDuration(next)
    }

    private var pageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pages").font(.subheadline.weight(.semibold)).foregroundStyle(ReadingPalette.secondaryInk)
            if totalPages != nil {
                GlassSegmentedControl(label: "How to enter pages", options: ManualPagesStyle.allCases,
                                      selection: $draft.pagesStyle, title: { $0.rawValue })
            }
            if draft.pagesStyle == .count || totalPages == nil {
                HStack(spacing: 10) {
                    TextField("20", text: $draft.pageCount).frame(width: 90).accessibilityLabel("Pages read")
                    Text("pages read").foregroundStyle(ReadingPalette.secondaryInk)
                }
            } else {
                HStack(spacing: 10) {
                    TextField("From", text: $draft.fromPage).frame(width: 90).accessibilityLabel("Page you started on")
                    Text("to").foregroundStyle(ReadingPalette.secondaryInk)
                    TextField("To", text: $draft.toPage).frame(width: 90).accessibilityLabel("Page you stopped on")
                    if let totalPages { Text("of \(totalPages.formatted())").foregroundStyle(ReadingPalette.secondaryInk) }
                }
                Text("Your place in the book is saved too, so the library shows how far along you are.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
        }
    }

    // MARK: When

    private var whenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When?").font(.headline)
            HStack(spacing: 8) {
                ManualChip(title: "Today", isSelected: draft.day == .today) { choose(.today) }
                ManualChip(title: "Yesterday", isSelected: draft.day == .yesterday) { choose(.yesterday) }
                ManualChip(title: otherDayTitle, systemImage: "calendar", isSelected: isOtherDay) { showingCalendar = true }
                    .popover(isPresented: $showingCalendar, arrowEdge: .bottom) { calendarPopover }
            }
            if draft.includesTime { clockRows }
        }.readingPanel()
    }

    private var isOtherDay: Bool { if case .other = draft.day { return true } else { return false } }
    private var otherDayTitle: String { isOtherDay ? draft.dayText(now: Date(), zone: zone).capitalized : "Pick a date" }

    private func choose(_ day: ManualDayChoice) {
        if reduceMotion { draft.choose(day: day) } else { withAnimation(ReadingMotion.selection) { draft.choose(day: day) } }
    }

    private var calendarPopover: some View {
        DatePicker("Day", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
            .datePickerStyle(.graphical).labelsHidden().padding(12).frame(width: 260)
            .onChange(of: pickedDate) { date in
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                if calendar.isDate(date, inSameDayAs: Date()) { choose(.today) }
                else if let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()), calendar.isDate(date, inSameDayAs: yesterday) { choose(.yesterday) }
                else { choose(.other(date)) }
                showingCalendar = false
            }
    }

    private var finishBinding: Binding<ManualEntryParsing.Clock> {
        Binding(get: { draft.finishClock ?? Self.clock(of: Date(), in: zone) }, set: { draft.finishClock = $0 })
    }

    private static func clock(of date: Date, in zone: TimeZone) -> ManualEntryParsing.Clock {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return ManualEntryParsing.Clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    private var clockRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if draft.usesStartTime {
                HStack(spacing: 12) {
                    Text("Started").frame(width: 70, alignment: .leading)
                    ClockField(label: "Start time", clock: $draft.startClock, zone: zone)
                }
            }
            HStack(spacing: 12) {
                Text(draft.usesStartTime ? "Finished" : "Finished at").frame(width: 70, alignment: .leading)
                ClockField(label: "Finish time", clock: finishBinding, zone: zone)
                if draft.day == .today {
                    ManualChip(title: "Now", isSelected: draft.finishesNow) { draft.finishClock = nil }
                }
            }
            Button(draft.usesStartTime ? "Use a length instead" : "I know when I started") {
                if reduceMotion { draft.usesStartTime.toggle() } else { withAnimation(ReadingMotion.selection) { draft.usesStartTime.toggle() } }
            }
            .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.accent)
        }
    }

    // MARK: Audiobook form

    private var audiobookForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where are you now?").font(.headline)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your place").font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
                        TextField("2:15:00", text: $draft.audioPosition).accessibilityLabel("Current content position")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total length").font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.secondaryInk)
                        TextField("10:00:00", text: $draft.audioTotal).accessibilityLabel("Total content duration")
                    }
                }
                Text("Use hours:minutes:seconds, hours:minutes, or a number of minutes. A place on its own adds no listening time or pages.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }.readingPanel()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Text("Also log listening time")
                    Spacer(minLength: 4)
                    GlassSwitch(label: "Also log listening time", isOn: Binding(
                        get: { draft.logsListeningTime },
                        set: { value in
                            if reduceMotion { draft.logsListeningTime = value } else { withAnimation(ReadingMotion.selection) { draft.logsListeningTime = value } }
                        }))
                }
                if draft.logsListeningTime { lengthControls.transition(formTransition) }
                Text("Enter the time you actually listened, excluding breaks. At 2×, one hour of content takes about 30 minutes.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }.readingPanel()
            if draft.logsListeningTime { whenCard.transition(formTransition) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = saveError ?? issue.map({ $0.message(zone: zone) }) {
                let prompt = saveError == nil && (issue?.isIncomplete ?? false)
                Label(message, systemImage: prompt ? "info.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(prompt ? ReadingPalette.secondaryInk : ReadingPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary = draft.summary(book: nil, now: Date(), zone: zone) {
                Label(summary, systemImage: "checkmark.circle").font(.callout.weight(.medium))
                    .foregroundStyle(ReadingPalette.ink).fixedSize(horizontal: false, vertical: true)
            } else if draft.kind == .audiobook, issue == nil {
                Label("Saves your place at \(draft.audioPosition) of \(draft.audioTotal)", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(saving ? "Saving…" : (draft.kind == .book ? "Add reading time" : "Save listening")) { save() }
                    .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil || saving)
            }
        }
    }

    // MARK: Saving

    private func save() {
        guard issue == nil, let book = chosenBook, !saving else { return }
        saving = true; saveError = nil
        Task {
            var cover: Data?
            if case let .outside(outside)? = choice, book.isNew { cover = try? await service.coverData(for: outside) }
            let now = Date()
            let existing = model.intervals.filter { $0.disposition != .excluded }
            let built = draft.entry(bookID: book.record.id, totalPages: totalPages, existing: existing, now: now, zone: zone)
            var saved = false
            switch draft.kind {
            case .book:
                if let entry = built.entry, built.issue == nil { saved = model.addManualEntry(book: book.record, cover: cover, entry: entry) }
            case .audiobook:
                if let audio = draft.audio().value {
                    let entry = draft.includesTime ? built.entry : nil
                    if draft.includesTime && built.issue != nil { break }
                    saved = model.logAudiobook(book: book.isNew ? nil : book.record, title: book.record.title,
                                               author: book.record.author ?? "", audio: audio,
                                               start: entry?.start, end: entry?.end ?? now)
                }
            }
            saving = false
            if saved { dismiss() }
            else { saveError = model.errorMessage ?? "Could not save. Your entries are still here; try again." }
        }
    }
}
