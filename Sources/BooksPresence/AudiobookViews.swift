import SwiftUI
import AppKit
import BooksCore

@MainActor
struct AudiobookLibraryPlayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: AudiobookPlayer
    var body: some View {
        if let id = player.bookID, let book = model.books.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(book.title, systemImage: "headphones").font(.headline)
                    Spacer()
                    Button("Close player") {
                        do { try player.close() } catch { model.errorMessage = String(describing: error) }
                    }
                }
                AudiobookPlaybackControls(player: player)
            }.readingPanel()
        }
    }
}

@MainActor
struct AudiobookSection: View {
    @ObservedObject var model: AppModel
    let book: BookRecord
    @ObservedObject var player: AudiobookPlayer
    @State private var logging = false
    @State private var removing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Book format", systemImage: "headphones").font(.headline)
                Spacer()
                ReadingSegmentedControl(label: "Book format", options: BookFormat.allCases,
                    selection: Binding(get: { book.resolvedFormat }, set: { model.setBookFormat($0, for: book) }),
                    title: { $0 == .text ? "Text" : "Audiobook" },
                    systemImage: { $0 == .text ? "book.closed" : "headphones" })
                    .frame(width: 260)
                    .accessibilityIdentifier("book-format")
            }
            if book.resolvedFormat == .audiobook {
                if let audio = model.audiobookProgress(for: book.id) {
                    Text("\(audio.fraction.formatted(.percent.precision(.fractionLength(0...1)))) · \(audio.description)")
                        .font(.title3.monospacedDigit())
                    ProgressView(value: audio.fraction).accessibilityLabel("Audiobook content progress")
                } else {
                    Text("Add your current position and total duration.").foregroundStyle(ReadingPalette.secondaryInk)
                }
                if player.bookID == book.id {
                    AudiobookPlaybackControls(player: player)
                } else if book.audioFileName != nil {
                    Button { model.openAudiobook(book) } label: { Label("Open audio player", systemImage: "play.circle") }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                }
                HStack {
                    Button("Log listening…") { logging = true }
                    Spacer()
                    if book.audioFileName == nil {
                        Button(model.importingAudio ? "Importing…" : "Import local audio…") { model.chooseAudiobook(for: book) }
                            .disabled(model.importingAudio)
                    } else {
                        Button("Remove audio copy…") { removing = true }
                    }
                }
                Text("Position measures content. Listening time records actual elapsed time, at any speed. Local playback stays private and does not publish to Discord.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(ReadingPalette.warning) }
            }
        }
        .readingPanel()
        .sheet(isPresented: $logging) { AudiobookLogView(model: model, book: book) }
        .alert("Remove the managed audio copy?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Move copy to Trash", role: .destructive) { model.removeAudiobook(book) }
        } message: { Text("Your original audio file, saved position, and listening history stay intact.") }
    }
}

@MainActor
struct AudiobookPlaybackControls: View {
    @ObservedObject var player: AudiobookPlayer
    @State private var seeking = false
    @State private var draftPosition: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(AudiobookProgress.timestamp(player.position)) / \(AudiobookProgress.timestamp(player.duration))")
                .font(.callout.monospacedDigit()).accessibilityLabel("Playback position")
            Slider(value: Binding(get: { seeking ? draftPosition : player.position }, set: { draftPosition = $0 }),
                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                if editing { draftPosition = player.position; seeking = true }
                else { seeking = false; player.seek(to: draftPosition) }
            }).accessibilityLabel("Seek in audiobook")
            HStack(spacing: 16) {
                Button { player.seek(to: player.position - 15) } label: { Image(systemName: "gobackward.15") }
                    .accessibilityLabel("Back 15 seconds")
                Button { if player.isPlaying { player.pauseReportingErrors() } else { player.play() } } label: {
                    Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                Button { player.seek(to: player.position + 30) } label: { Image(systemName: "goforward.30") }
                    .accessibilityLabel("Forward 30 seconds")
                Spacer()
                ReadingMenuPicker(label: "Playback speed", options: [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2],
                    selection: $player.rate) { "\($0.formatted())×" }
                    .frame(width: 100)
                    .accessibilityIdentifier("playback-speed")
            }
            HStack {
                Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                Slider(value: $player.volume, in: 0...1).accessibilityLabel("Volume").frame(maxWidth: 160)
            }
            if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(ReadingPalette.warning) }
        }
    }
}

@MainActor
struct AudiobookLogView: View {
    @ObservedObject var model: AppModel
    var book: BookRecord? = nil
    var maximumHeight: CGFloat = 640
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var title = ""
    @State private var author = ""
    @State private var position = ""
    @State private var total = ""
    @State private var includeSession = false
    @State private var start = Date().addingTimeInterval(-1800)
    @State private var end = Date()
    @State private var saveError: String?

    init(model: AppModel, book: BookRecord? = nil, maximumHeight: CGFloat = 640, initiallyIncludesSession: Bool = false) {
        self.model = model
        self.book = book
        self.maximumHeight = maximumHeight
        _includeSession = State(initialValue: initiallyIncludesSession)
    }

    private var selectedBook: BookRecord? { (book ?? model.books.first { $0.id == selectedID }).flatMap { model.canonicalLibraryBook($0) } }
    private var audio: AudiobookProgress? {
        guard let position = AudiobookProgress.parse(position), let duration = AudiobookProgress.parse(total) else { return nil }
        let value = AudiobookProgress(positionSeconds: position, durationSeconds: duration)
        return value.isValid ? value : nil
    }
    private var validationMessage: String? {
        if selectedBook == nil && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a title or choose a book from your library."
        }
        guard let duration = AudiobookProgress.parse(total), duration.isFinite, duration > 0 else {
            return "Enter a total duration greater than zero, such as 10:00:00."
        }
        guard let current = AudiobookProgress.parse(position), current.isFinite, current >= 0 else {
            return "Enter a valid position, such as 2:15:00, or 0 for the beginning."
        }
        if current > duration { return "The current position cannot exceed the total duration." }
        if includeSession {
            if end <= start { return "The stopped time must be after the started time." }
            if end > Date() { return "Listening sessions must finish no later than now." }
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadingSheetHeader(title: "Log listening", subtitle: nil, close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let book { Text(book.title).font(ReadingType.bookTitle(20)) }
                        else {
                            let books = model.books.filter { model.canonicalLibraryBook($0)?.id == $0.id }
                                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                            ReadingMenuPicker(label: "Book", options: [""] + books.map(\.id), selection: $selectedID) { id in
                                books.first { $0.id == id }?.title ?? "New audiobook"
                            }.onChange(of: selectedID) { _ in loadPosition() }
                            if selectedID.isEmpty {
                                TextField("Title", text: $title)
                                TextField("Author (optional)", text: $author)
                            }
                        }
                        Text("Current content position").font(.caption.weight(.medium))
                        TextField("2:15:00", text: $position).accessibilityLabel("Current content position")
                        Text("Total content duration").font(.caption.weight(.medium))
                        TextField("10:00:00", text: $total).accessibilityLabel("Total content duration")
                        Text("Use hours:minutes:seconds, hours:minutes, or a number of minutes.")
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }.readingPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        ReadingSwitchRow(title: "Also log a listening session", isOn: $includeSession)
                        if includeSession {
                            ReadingDatePicker("Started listening", selection: $start, maximumDate: Date())
                            ReadingDatePicker("Stopped listening", selection: $end, minimumDate: start, maximumDate: Date())
                            Text("Actual listening: \(ReadingFormat.duration(max(0, end.timeIntervalSince(start))))")
                                .font(.callout.monospacedDigit())
                        }
                        Text("Enter the time you actually listened, excluding breaks. At 2×, one hour of content takes about 30 minutes. Position alone adds no listening time or pages.")
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }.readingPanel()
                }
                .padding(2)
            }
            .scrollIndicators(.visible)
            Hairline()
            if let message = saveError ?? validationMessage {
                Text(message).font(.caption)
                    .foregroundStyle(saveError == nil ? ReadingPalette.secondaryInk : ReadingPalette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save listening") {
                    guard validationMessage == nil, let audio else { return }
                    if model.logAudiobook(book: selectedBook, title: title, author: author, audio: audio,
                        start: includeSession ? start : nil, end: includeSession ? end : Date()) { dismiss() }
                    else { saveError = model.errorMessage ?? "Could not save listening. Your entries are still here; try again." }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(26)
        .frame(width: 550, height: min(maximumHeight, max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
        .readingSheetSurface()
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink).tint(ReadingPalette.accent)
        .textFieldStyle(ReadingTextFieldStyle()).buttonStyle(ReadingButtonStyle())
        .onAppear { loadPosition() }
        .onChange(of: title) { _ in saveError = nil }
        .onChange(of: author) { _ in saveError = nil }
        .onChange(of: position) { _ in saveError = nil }
        .onChange(of: total) { _ in saveError = nil }
        .onChange(of: start) { _ in saveError = nil }
        .onChange(of: end) { _ in saveError = nil }
        .onChange(of: includeSession) { _ in saveError = nil }
    }
    private func loadPosition() {
        saveError = nil
        if let book = selectedBook, let saved = model.audiobookProgress(for: book.id) {
            position = AudiobookProgress.timestamp(saved.positionSeconds); total = AudiobookProgress.timestamp(saved.durationSeconds)
        } else { position = "0:00:00"; total = "" }
    }
}
