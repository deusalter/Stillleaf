import Foundation
@testable import BooksPlatform

enum BookSearchSmokeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw BookSearchSmokeFailure.failed(message) }
}

/// A stub catalogue: per-query delays and failures, and a log of what was asked and cancelled.
private actor Log {
    var asked: [String] = []
    var cancelled: [String] = []
    func ask(_ query: String) { asked.append(query) }
    func cancel(_ query: String) { cancelled.append(query) }
}

private struct StubService: BookSearchService {
    let log = Log()
    var delays: [String: UInt64] = [:]
    var failures: [String: BookSearchError] = [:]

    func search(_ query: String) async throws -> [OutsideBook] {
        await log.ask(query)
        if let delay = delays[query] {
            do { try await Task.sleep(nanoseconds: delay) }
            catch { await log.cancel(query); throw error }
        }
        if let failure = failures[query] { throw failure }
        return [OutsideBook(key: "/works/OL\(query.count)W", title: query.capitalized)]
    }
    func coverData(for book: OutsideBook) async throws -> Data? { nil }
}

private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

@MainActor
private func run() async throws {
    // Typing in bursts sends one request, for the final text.
    var stub = StubService()
    var controller = BookSearchController(service: stub, debounce: 0.6)
    for text in ["pi", "pir", "pira", "piranesi"] { controller.update(query: text); await wait(0.01) }  // timers here fire ~100 ms late, so four keystrokes span ~400 ms
    try require(controller.phase == .loading, "not loading during the pause")
    await wait(1.4)
    let asked = await stub.log.asked
    try require(asked == ["piranesi"], "debounce failed: \(asked)")
    try require(controller.phase == .results([OutsideBook(key: "/works/OL8W", title: "Piranesi")]), "results missing: \(controller.phase)")

    // One character is not worth a request; clearing returns to idle.
    controller.update(query: "p"); try require(controller.phase == .idle, "one character searched")
    controller.update(query: "  "); try require(controller.phase == .idle, "blank searched")
    let afterShort = await stub.log.asked
    try require(afterShort == ["piranesi"], "short query reached the network")
    controller.update(query: "piranesi")

    // Repeating a finished search is answered from memory.
    controller.update(query: "dune"); await wait(1.0)
    controller.update(query: "Piranesi ")
    try require(controller.phase == .results([OutsideBook(key: "/works/OL8W", title: "Piranesi")]), "cached search was not instant")
    await wait(0.4)
    let afterRepeat = await stub.log.asked
    try require(afterRepeat == ["piranesi", "dune"], "cache missed: \(afterRepeat)")

    // A slow search that a newer one overtakes is cancelled and never shown.
    stub = StubService(delays: ["slow one": 2_000_000_000])
    controller = BookSearchController(service: stub, debounce: 0.2)
    controller.update(query: "slow one"); await wait(0.8)
    controller.update(query: "fast one"); await wait(1.0)
    let overtaken = await stub.log.cancelled
    try require(overtaken == ["slow one"], "stale request was not cancelled: \(overtaken)")
    try require(controller.phase == .results([OutsideBook(key: "/works/OL8W", title: "Fast One")]), "stale result shown: \(controller.phase)")

    // Offline degrades to a state; retry recovers.
    stub = StubService(failures: ["lost book": .offline])
    controller = BookSearchController(service: stub, debounce: 0.1)
    controller.update(query: "lost book"); await wait(0.8)
    try require(controller.phase == .failed(.offline), "offline not reported: \(controller.phase)")
    stub.failures = [:]
    controller = BookSearchController(service: stub, debounce: 0.1)
    controller.update(query: "lost book"); await wait(0.8)
    try require(controller.phase != .failed(.offline), "recovery failed")

    // A server error is distinct from being offline, and cancel() abandons everything.
    stub = StubService(failures: ["broken": .unavailable(status: 503)])
    controller = BookSearchController(service: stub, debounce: 0.1)
    controller.update(query: "broken"); await wait(0.8)
    try require(controller.phase == .failed(.unavailable), "server error not reported")
    controller.cancel(); try require(controller.phase == .idle, "cancel left state behind")

    // The real client's request carries only the query.
    let request = OpenLibraryClient.request(for: "piranesi")
    try require(request?.url?.absoluteString == "https://openlibrary.org/search.json?q=piranesi&fields=key,title,author_name,cover_i,number_of_pages_median,first_publish_year&limit=8",
                "unexpected request: \(request?.url?.absoluteString ?? "nil")")
    let books = try OpenLibraryClient.decode(Data(#"{"docs":[{"key":"/works/OL1W","title":"Piranesi","author_name":["Susanna Clarke"],"cover_i":10,"number_of_pages_median":272},{"key":"/x","title":"no"}]}"#.utf8))
    try require(books.count == 1 && books[0].pageCount == 272 && books[0].libraryID == "openlibrary:OL1W", "decode wrong")
    print("book-search-smoke: passed")
}

@main
struct BookSearchSmoke {
    static func main() async {
        do { try await run(); exit(0) }
        catch { fputs("book-search-smoke: \(error)\n", stderr); exit(1) }
    }
}
