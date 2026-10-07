import SwiftUI
import BooksCore
import BooksPlatform

/// Canned catalogue for renders and smokes: no network, no waiting.
struct PreviewBookSearch: BookSearchService {
    var results: [OutsideBook] = []
    var failure: BookSearchError?

    func search(_ query: String) async throws -> [OutsideBook] {
        if let failure { throw failure }
        return results
    }
    func coverData(for book: OutsideBook) async throws -> Data? { nil }

    static let piranesi = OutsideBook(key: "/works/OL20099011W", title: "Piranesi", author: "Susanna Clarke",
                                      coverID: 10, pageCount: 272, firstPublishYear: 2020)
    static let notebooks = OutsideBook(key: "/works/OL1W", title: "The Piranesi Notebooks", author: "Hélène Bessette", firstPublishYear: 1964)
}

/// The sheet's states for `--render-ui`, built from real views over a disposable model.
@MainActor
func manualEntryPreviews(model: AppModel) -> [(String, AnyView)] {
    func sheet(_ preview: ManualAdditionView.Preview, service: BookSearchService = PreviewBookSearch()) -> AnyView {
        AnyView(ManualAdditionView(model: model, service: service, preview: preview))
    }
    let found = [PreviewBookSearch.piranesi, PreviewBookSearch.notebooks]
    // A day with no seeded history, so the sheets show their summary rather than an overlap warning.
    let quietDay = ManualDayChoice.other(Date().addingTimeInterval(-9 * 86_400))
    var yesterday = ManualEntryDraft(); yesterday.choose(day: quietDay); yesterday.preset = .threeQuarters
    var pages = ManualEntryDraft(); pages.choose(day: quietDay); pages.content = .both; pages.pagesStyle = .range; pages.fromPage = "10"; pages.toPage = "30"
    var pagesOnly = ManualEntryDraft(); pagesOnly.choose(day: .yesterday); pagesOnly.content = .pages; pagesOnly.pageCount = "25"
    var audio = ManualEntryDraft(); audio.kind = .audiobook; audio.audioPosition = "2:15:00"; audio.audioTotal = "10:00:00"
    audio.choose(day: quietDay); audio.logsListeningTime = true; audio.preset = .hour
    let waves = model.books.first { $0.title == "The Waves" }
    return [
        ("manual-add", sheet(.init())),
        ("manual-add-library", sheet(.init(query: "wa", searchPhase: .results([.init(key: "/works/OL2W", title: "Waverley", author: "Walter Scott", pageCount: 640)])))),
        ("manual-add-outside", sheet(.init(query: "piranesi", searchPhase: .results(found)))),
        ("manual-add-searching", sheet(.init(query: "piranesi", searchPhase: .loading))),
        ("manual-add-offline", sheet(.init(query: "piranesi", searchPhase: .failed(.offline)))),
        ("manual-add-time", sheet(.init(choice: waves.map { .library($0) }, draft: yesterday))),
        ("manual-add-pages", sheet(.init(choice: .outside(PreviewBookSearch.piranesi), draft: pages))),
        ("manual-add-pages-only", sheet(.init(choice: .typed("A paperback from the shop"), draft: pagesOnly))),
        ("manual-add-audiobook", sheet(.init(choice: .library(BookRecord(id: "preview-audio", title: "The Waves", author: "Virginia Woolf", format: .audiobook)), draft: audio)))
    ]
}

/// The save path end to end on a disposable model: a catalogue book with time and a page range, then
/// pages alone, then a rejected overlap.
@MainActor
func checkManualEntry(_ model: AppModel) throws {
    func fail(_ message: String) -> BooksAccessErrorForUI { BooksAccessErrorForUI.failed("Manual entry: \(message) (\(model.errorMessage ?? "no error"))") }
    let book = BookRecord(id: "openlibrary:OLSMOKEW", title: "Smoke Catalogue Book", author: "Synthetic", source: "Open Library", pageCount: 272)
    let end = Date().addingTimeInterval(-7 * 86_400)
    let timed = ManualReadingEntry(bookID: book.id, end: end, seconds: 1_800, pages: .range(from: 10, to: 30),
                                   totalPages: 272, timezoneID: model.timezoneID)
    guard model.addManualEntry(book: book, entry: timed) else { throw fail("time and pages were not saved") }
    guard let saved = model.books.first(where: { $0.id == book.id }), saved.pageCount == 272, saved.source == "Open Library" else {
        throw fail("the catalogue book did not join the library with its page count")
    }
    guard model.manualPages(forBookID: book.id) == 20, model.totalPages(for: saved) == 272 else {
        throw fail("manual pages were not exposed to the book (\(model.manualPages(forBookID: book.id)))")
    }
    let pagesOnly = ManualReadingEntry(bookID: book.id, end: end.addingTimeInterval(-3 * 3_600), seconds: 0,
                                       pages: .count(15), timezoneID: model.timezoneID)
    guard model.addManualEntry(book: saved, entry: pagesOnly), model.manualPages(forBookID: book.id) == 35 else {
        throw fail("pages without time were not saved")
    }
    let credited = model.intervals.filter { $0.bookID == book.id }.reduce(0) { $0 + $1.duration }
    guard abs(credited - 1_800) < 0.01 else { throw fail("pages alone credited time (\(credited) seconds)") }
    let clash = ManualReadingEntry(bookID: book.id, end: end.addingTimeInterval(600), seconds: 1_200, timezoneID: model.timezoneID)
    model.errorMessage = nil
    guard !model.addManualEntry(book: saved, entry: clash), model.errorMessage?.contains("already have reading recorded") == true else {
        throw fail("overlapping time was accepted or unexplained")
    }
    model.errorMessage = nil
}
