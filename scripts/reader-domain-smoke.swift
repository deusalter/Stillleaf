import Foundation
import BooksCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

var queue = EPUBImportQueue()
let first = URL(fileURLWithPath: "/fixtures/One.epub")
let second = URL(fileURLWithPath: "/fixtures/Two.EPUB")
queue.enqueue([first, second, first, URL(fileURLWithPath: "/fixtures/notes.txt")])
check(queue.items.count == 3, "Repeated OS paths should coalesce within the queue")
check(queue.consumeLibraryPresentation(), "An import must request Library presentation")
check(!queue.consumeLibraryPresentation(), "Presentation requests must be consumed once")
check(queue.items.filter { $0.state == .failed }.count == 1, "Invalid files need per-item outcomes")
let job = queue.takeNext()!
check(job.url == first && queue.takeNext() == nil, "Only one import may execute at a time")
queue.enqueue([first, second])
check(queue.items.count == 3, "Warm OS events must not duplicate queued/running imports")
queue.cancelPending()
check(queue.items.first(where: { $0.url == second })?.state == .cancelled, "Cancellation must skip pending imports")
queue.finish(id: job.id, result: .imported(publicationID: "edition-one"))
check(queue.summary.imported == 1 && queue.summary.cancelled == 1 && queue.summary.failed == 1,
      "Partial batch outcomes must remain accurate")
check(queue.takeNext() == nil, "Cancelled jobs must not run")
queue.enqueue([first])
check(queue.takeNext()?.url == first, "A later explicit open must be allowed after a completed batch")
let later = queue.items.last!
queue.finish(id: later.id, result: .alreadyImported(publicationID: "edition-one"))
check(queue.summary.duplicates == 1, "Existing publication must be a duplicate outcome, not a reader launch")

var policy = ReaderEventPolicy(publicationID: "edition", documentToken: "document", openedAtUptime: 10)
let locator = ReaderLocator(publicationID: "edition", href: "chapter.xhtml", anchor: "epubcfi(/6/2!/4/2)")
func event(_ sequence: UInt64, _ cause: ReaderNavigationCause, _ uptime: Double = 11,
           token: String = "document", location: ReaderLocator = locator) -> ReaderNavigationEvent {
    ReaderNavigationEvent(documentToken: token, sequence: sequence, cause: cause, locator: location,
                          observedAtUptime: uptime)
}
check(policy.accept(event(1, .restore), receiptUptime: 11, eligible: true)?.countsAsActivity == false,
      "Restore cannot renew reading activity")
check(policy.accept(event(2, .turn), receiptUptime: 11, eligible: true)?.countsAsActivity == true,
      "Eligible explicit turn should renew activity")
check(policy.accept(event(2, .turn), receiptUptime: 11, eligible: true) == nil, "Reject replayed events")
check(policy.accept(event(3, .turn, token: "forged"), receiptUptime: 11, eligible: true) == nil,
      "Reject events from another document")
check(policy.accept(event(3, .layout), receiptUptime: 11, eligible: true)?.countsAsActivity == false,
      "Reflow cannot renew activity")
check(policy.accept(event(4, .jump), receiptUptime: 11, eligible: true)?.countsAsActivity == false,
      "Jump cannot claim sequential reading")
check(policy.accept(event(5, .turn), receiptUptime: 11, eligible: false)?.countsAsActivity == false,
      "Hidden/ineligible reader cannot renew activity")
check(policy.accept(event(6, .turn, 5), receiptUptime: 11, eligible: true) == nil, "Reject stale event")
check(policy.accept(event(6, .turn, .nan), receiptUptime: 11, eligible: true) == nil, "Reject invalid clock")
check(policy.accept(event(6, .turn, 14), receiptUptime: 11, eligible: true) == nil, "Reject future event")
check(policy.accept(event(6, .turn, location: ReaderLocator(publicationID: "other", href: "chapter.xhtml")),
                    receiptUptime: 11, eligible: true) == nil, "Reject another publication")
check(policy.accept(event(6, .turn, location: ReaderLocator(publicationID: "edition", href: "../secret")),
                    receiptUptime: 11, eligible: true) == nil, "Reject resource traversal")
check(policy.accept(event(6, .assistiveNavigation), receiptUptime: 11, eligible: true)?.countsAsActivity == true,
      "Rejected events must not advance sequence; assistive navigation is valid activity")
print("reader-domain-smoke: queue, cancellation, duplicate outcomes, navigation provenance passed")
