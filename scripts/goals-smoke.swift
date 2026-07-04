import Foundation
import BooksCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let goals = [
    GoalChange(effectiveDay: "2027-01-01", minutes: 25, pages: 10, primaryUnit: .minutes),
    GoalChange(effectiveDay: "2027-01-02", minutes: 25, pages: 10, primaryUnit: .pages)
]
let minuteProgress = ReadingGoals.daily(day: "2027-01-01", pages: 20, creditedSeconds: 1_500, goals: goals)
check(minuteProgress.unit == .minutes && minuteProgress.reached, "minute goal did not use its historical mode")
let pageProgress = ReadingGoals.daily(day: "2027-01-02", pages: 10, creditedSeconds: 0, goals: goals)
check(pageProgress.unit == .pages && pageProgress.reached, "page goal did not use its historical mode")

let date = ISO8601DateFormatter().date(from: "2027-01-01T00:30:00Z")!
let books = [BookRecord(id: "source", title: "Source"), BookRecord(id: "target", title: "Target")]
let events = books.map { book in
    AuditEvent(date: date, kind: "bookCompleted", bookID: book.id, detail: "Completion",
               completion: BookCompletionEvidence(finishedAt: date, source: "User edit", imported: false))
}
check(ReadingGoals.finishedCount(year: 2026, timezoneID: "America/Los_Angeles", books: books,
                                 events: events, merges: [BookMerge(sourceID: "source", targetID: "target")],
                                 now: date.addingTimeInterval(1)) == 1,
      "annual count did not honor timezone and merged identities")
let oldDate = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
let correctedDate = ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")!
let corrected = [
    AuditEvent(date: oldDate, kind: "bookCompleted", bookID: "source", detail: "Imported completion",
               completion: BookCompletionEvidence(finishedAt: oldDate, source: "Catalog", imported: true)),
    AuditEvent(date: correctedDate, kind: "bookCompleted", bookID: "target", detail: "Correction",
               completion: BookCompletionEvidence(finishedAt: correctedDate, source: "Catalog", imported: true))
]
check(ReadingGoals.finishedCount(year: 2026, timezoneID: "UTC", books: books, events: corrected,
                                 merges: [BookMerge(sourceID: "source", targetID: "target")],
                                 now: correctedDate.addingTimeInterval(1)) == 0,
      "merged completion correction left the canonical book in its old year")
check(ReadingGoals.finishedCount(year: 2027, timezoneID: "UTC", books: books, events: corrected,
                                 merges: [BookMerge(sourceID: "source", targetID: "target")],
                                 now: correctedDate.addingTimeInterval(1)) == 1,
      "merged completion correction did not move the canonical book to its corrected year")

let reviewEvents = [
    AuditEvent(id: "review", date: date, kind: "bookReviewed", bookID: "target", detail: "Review",
               review: BookReviewEvidence(text: "Worth revisiting.")),
    AuditEvent(id: "clear", date: date.addingTimeInterval(1), kind: "bookReviewed", bookID: "target",
               detail: "Review cleared", review: BookReviewEvidence(text: nil))
]
check(BookHistory.review(bookID: "target", events: reviewEvents) == nil, "review clear did not win")

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let store = try ReadingStore(url: temporary.appendingPathComponent("history.sqlite"))
try store.saveBook(BookRecord(id: "target", title: "Target"))
try store.setGoal(goals[1])
let annual = AuditEvent(id: "annual", date: date, kind: "annualGoalChanged", detail: "Annual goal",
                        annualGoal: AnnualGoalEvidence(year: 2027, books: 20))
try store.appendEvent(annual)
try store.appendEvent(reviewEvents[0])
let json = temporary.appendingPathComponent("history.json")
try store.exportJSON(to: json)
let imported = try ReadingStore(url: temporary.appendingPathComponent("imported.sqlite"))
try imported.importJSON(from: json)
let archive = try imported.archive()
check(archive.goals.first?.resolvedUnit == .pages, "daily primary mode did not survive JSON")
check(ReadingGoals.annualTarget(year: 2027, events: archive.events) == 20,
      "annual target did not survive JSON")
check(BookHistory.review(bookID: "target", events: archive.events) == "Worth revisiting.",
      "written review did not survive JSON")
do {
    try store.appendEvent(AuditEvent(kind: "bookReviewed", bookID: "target", detail: "Too long",
                                     review: BookReviewEvidence(text: String(repeating: "x", count: 50_001))))
    fatalError("oversized review was accepted")
} catch is ReadingStoreError {}
print("goals-smoke: passed")

let atomicRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Stillleaf-goal-atomic-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: atomicRoot) }
let atomicStore = try ReadingStore(url: atomicRoot.appendingPathComponent("history.sqlite"))
let originalAnnual = AuditEvent(id: "annual-fixed", kind: "annualGoalChanged", detail: "Original",
    annualGoal: AnnualGoalEvidence(year: 2027, books: 12))
try atomicStore.appendEvent(originalAnnual)
var conflictingAnnual = originalAnnual
conflictingAnnual.annualGoal = AnnualGoalEvidence(year: 2027, books: 24)
do {
    try atomicStore.setReadingGoals(daily: GoalChange(effectiveDay: "2027-01-01", minutes: 30, pages: 20, primaryUnit: .minutes), annual: conflictingAnnual)
    fatalError("Conflicting annual goal should fail")
} catch { }
let afterFailure = try atomicStore.archive()
check(afterFailure.goals.isEmpty && ReadingGoals.annualTarget(year: 2027, events: afterFailure.events) == 12,
    "Failed joint goal save retained a partial daily change")
print("goals-smoke: atomic goal failure preserved both saved targets")
