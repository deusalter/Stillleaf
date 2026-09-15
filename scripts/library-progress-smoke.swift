import Foundation
import BooksCore

@main struct LibraryProgressSmoke {
    static func main() {
        func observation(page: Int? = nil, total: Int? = nil, fraction: Double? = nil, reliable: Bool = true) -> ProgressObservation {
            ProgressObservation(bookID: "test", page: page, totalPages: total, fraction: fraction, source: "fixture", reliable: reliable)
        }
        func label(_ value: ProgressObservation?) -> LibraryProgressLabel {
            LibraryProgressLabel.saved(value, pagesLogged: 706, finished: false)
        }
        precondition(label(observation(page: 706, total: 1000)).primary == "71%")
        precondition(label(observation(page: 706, total: 1000)).detail == "706 / 1,000 pages")
        precondition(label(observation(page: 7, total: 1000)).primary == "1%") // activity is not position
        precondition(label(observation(page: 706)).detail == "Total unavailable")
        precondition(label(observation(fraction: 0.42)).primary == "42%")
        let native = ProgressObservation(bookID: "test", fraction: 0.42,
            location: "Chapter 3 of 12 · Page 2 of 8", source: "stillleaf-reader", reliable: true)
        precondition(label(native).primary == "42%")
        precondition(label(native).detail == "Chapter 3 of 12 · Page 2 of 8")
        precondition(label(native).detail?.contains("706") == false) // activity never replaces position
        let pendingTotal = ProgressObservation(bookID: "test", location: "Chapter 3 of 12 · Page 2 of 8",
            source: "stillleaf-reader", reliable: true)
        precondition(label(pendingTotal).primary == "Chapter 3 of 12 · Page 2 of 8")
        precondition(label(pendingTotal).detail == nil)
        precondition(label(observation(page: 706, total: 1000, reliable: false)).primary == "706 pages logged")
        for value in [observation(page: 20, total: 10), observation(page: -1, total: 100), observation(page: 0, total: 0), observation(fraction: .nan), observation(fraction: 1.1)] {
            precondition(label(value).primary == "706 pages logged")
        }
        precondition(label(observation(page: 0, total: 100)).primary == "0%")
        precondition(label(observation(page: 100, total: 100)).primary == "100%")
        precondition(LibraryProgressLabel.saved(nil, pagesLogged: 0, finished: true).primary == "Finished")
        precondition(LibraryProgressLabel.saved(nil, pagesLogged: 0, finished: false).primary == "Position unavailable")
        precondition(LibraryProgressLabel.position(.time(current: 1800, total: 7200)) == LibraryProgressLabel(primary: "25%", detail: "30:00 / 2:00:00"))
        precondition(LibraryProgressLabel.position(.time(current: 60, total: nil))?.detail == "Duration unavailable")
        precondition(LibraryProgressLabel.position(.time(current: .infinity, total: 100)) == nil)
        print("library-progress-smoke: page position, missing totals, invalid evidence, activity fallback and content-time formatting passed")
    }
}
