import Foundation
import XCTest
@testable import BooksCore

final class ReaderDomainTests: XCTestCase {
    func testBatchPartialFailureAndCancellationPreserveActualOutcomes() {
        var queue = EPUBImportQueue()
        let first = URL(fileURLWithPath: "/fixtures/one.epub")
        let second = URL(fileURLWithPath: "/fixtures/two.epub")
        queue.enqueue([first, second, first, URL(string: "https://example.com/book.epub")!])
        XCTAssertEqual(queue.items.count, 3)
        XCTAssertTrue(queue.consumeLibraryPresentation())
        XCTAssertFalse(queue.consumeLibraryPresentation())
        let active = queue.takeNext()!
        XCTAssertNil(queue.takeNext())
        queue.cancelPending()
        queue.finish(id: active.id, result: .imported(publicationID: "one"))
        XCTAssertEqual(queue.summary.imported, 1)
        XCTAssertEqual(queue.summary.cancelled, 1)
        XCTAssertEqual(queue.summary.failed, 1)
        XCTAssertFalse(queue.isBusy)
        // A delayed callback cannot change a job's already durable outcome.
        queue.finish(id: active.id, result: .failed(message: "late"))
        XCTAssertEqual(queue.summary.imported, 1)
    }

    func testRepeatedOpenWhileBusyDeduplicatesAndLaterOpenCanResolveExistingEdition() {
        var queue = EPUBImportQueue()
        let url = URL(fileURLWithPath: "/fixtures/book.EPUB")
        queue.enqueue([url])
        let first = queue.takeNext()!
        queue.enqueue([url])
        XCTAssertEqual(queue.items.count, 1)
        queue.finish(id: first.id, result: .imported(publicationID: "edition"))
        queue.enqueue([url])
        let reopened = queue.takeNext()!
        queue.finish(id: reopened.id, result: .alreadyImported(publicationID: "edition"))
        XCTAssertEqual(queue.summary.duplicates, 1)
        XCTAssertEqual(queue.items.first?.publicationID, "edition")
    }

    func testBatchBoundReportsOverflowWithoutRunningIt() {
        var queue = EPUBImportQueue()
        queue.enqueue((0..<1_003).map { URL(fileURLWithPath: "/fixtures/\($0).epub") })
        XCTAssertEqual(queue.items.count, 1_000)
        XCTAssertEqual(queue.summary.failed, 3)
        XCTAssertEqual(queue.summary.remaining, 1_000)
    }

    func testOnlyEligibleIntentionalNavigationRenewsActivity() {
        var policy = ReaderEventPolicy(publicationID: "edition", documentToken: "token", openedAtUptime: 10)
        let locator = ReaderLocator(publicationID: "edition", href: "chapter.xhtml")
        for (index, cause) in [ReaderNavigationCause.restore, .layout, .jump, .heartbeat].enumerated() {
            let result = policy.accept(ReaderNavigationEvent(documentToken: "token", sequence: UInt64(index),
                cause: cause, locator: locator, observedAtUptime: 11), receiptUptime: 11, eligible: true)
            XCTAssertEqual(result?.countsAsActivity, false)
        }
        let turn = ReaderNavigationEvent(documentToken: "token", sequence: 4, cause: .turn,
                                         locator: locator, observedAtUptime: 11)
        XCTAssertEqual(policy.accept(turn, receiptUptime: 11, eligible: true)?.countsAsActivity, true)
        XCTAssertNil(policy.accept(turn, receiptUptime: 11, eligible: true))
        var hidden = turn; hidden.sequence = 5
        XCTAssertEqual(policy.accept(hidden, receiptUptime: 11, eligible: false)?.countsAsActivity, false)
    }

    func testWrongDocumentStaleAndInvalidLocatorEventsDoNotAdvanceSequence() {
        var policy = ReaderEventPolicy(publicationID: "edition", documentToken: "token", openedAtUptime: 10)
        var event = ReaderNavigationEvent(documentToken: "wrong", sequence: 1, cause: .turn,
            locator: ReaderLocator(publicationID: "edition", href: "chapter.xhtml"), observedAtUptime: 11)
        XCTAssertNil(policy.accept(event, receiptUptime: 11, eligible: true))
        event.documentToken = "token"; event.observedAtUptime = 6
        XCTAssertNil(policy.accept(event, receiptUptime: 11, eligible: true))
        event.observedAtUptime = 11; event.locator.href = "%2e%2e/secret"
        XCTAssertNil(policy.accept(event, receiptUptime: 11, eligible: true))
        event.locator.href = "chapter.xhtml"
        XCTAssertNotNil(policy.accept(event, receiptUptime: 11, eligible: true))
    }
}
