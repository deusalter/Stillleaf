import Foundation
import CSQLite
import BooksCore
@testable import BooksPlatform

// Replay the observed chapter-container churn through the real layout adapter
// and tracker. All geometry is synthetic; no personal reader data is accessed.
let readerHost = CGSize(width: 1280, height: 769)
let chapterWidths: [[CGFloat]] = [[1134], [531, 531], [530, 530], [1135], [1134], [1135], [1134]]
let footerPages = [340, 341, 341, 342, 343, 344, 345]
let fixtureStart = Date(timeIntervalSince1970: 1_700_000_000)
var layoutTracker = PageTurnTracker()
var countedPages = 0
var layoutSignatures = Set<String>()
for (index, widths) in chapterWidths.enumerated() {
    let position = BooksReaderLayout.position(page: footerPages[index], totalPages: nil,
        windowSize: readerHost, readerSize: readerHost,
        paneSizes: widths.map { CGSize(width: $0, height: 613) })!
    precondition(position.visiblePages == 1)
    layoutSignatures.insert(position.layoutSignature)
    countedPages += layoutTracker.observe(bookID: "fixture", sessionID: "reading", position: position,
        date: fixtureStart.addingTimeInterval(Double(index)), uptime: 100 + Double(index))?.pagesRead ?? 0
}
precondition(countedPages == 5 && layoutSignatures.count == 1)
let resized = BooksReaderLayout.position(page: 346, totalPages: nil,
    windowSize: CGSize(width: 1281, height: 769), readerSize: readerHost, paneSizes: [readerHost])!
precondition(!layoutSignatures.contains(resized.layoutSignature))
precondition(layoutTracker.observe(bookID: "fixture", sessionID: "reading", position: resized,
    date: fixtureStart.addingTimeInterval(7), uptime: 107) == nil)
precondition(BooksReaderLayout.position(page: 1, totalPages: nil,
    windowSize: readerHost, readerSize: .zero, paneSizes: [readerHost]) == nil)
precondition(BooksReaderLayout.position(page: 1, totalPages: nil,
    windowSize: readerHost, readerSize: readerHost, paneSizes: []) == nil)
print("books-smoke: chapter splits/pixel jitter count all five pages; actual resize resets")

let reader = BooksReaderEvidence(booksVersion: "8.0", identifier: "SceneWindow", role: "AXWindow", subrole: "AXStandardWindow",
    minimized: false, modal: false, webAreaCount: 1, visibleReaderWebAreaCount: 1,
    hasLibraryNavigation: false, inspectionComplete: true, pageNavigationToken: "books8-page:52")
precondition(reader.permitsUniqueTitleMatch)
let mutations: [(inout BooksReaderEvidence) -> Void] = [
    { $0.booksVersion = "8.1" }, { $0.identifier = nil }, { $0.role = "AXGroup" }, { $0.subrole = "AXDialog" },
    { $0.minimized = true }, { $0.modal = true }, { $0.webAreaCount = 0; $0.visibleReaderWebAreaCount = 0 },
    { $0.webAreaCount = 2; $0.visibleReaderWebAreaCount = 1 }, { $0.visibleReaderWebAreaCount = 0 },
    { $0.hasLibraryNavigation = true }, { $0.inspectionComplete = false }
]
for mutate in mutations { var evidence = reader; mutate(&evidence); precondition(!evidence.permitsUniqueTitleMatch) }
var twoPageReader = reader
twoPageReader.webAreaCount = 2; twoPageReader.visibleReaderWebAreaCount = 2
precondition(twoPageReader.permitsUniqueTitleMatch)
var threePageReader = reader
threePageReader.webAreaCount = 3; threePageReader.visibleReaderWebAreaCount = 3
precondition(!threePageReader.permitsUniqueTitleMatch)
precondition(BooksPageNavigationToken.parse(description: "Page 52") == "books8-page:52")
precondition(BooksPageNavigationToken.parse(description: "Page 69 of 701") == "books8-page:69")
precondition(BooksPageNavigationToken.parse(description: "Page 10000000 of 10000000") == "books8-page:10000000")
precondition(BooksPageNavigationToken.position(description: "Page 52")?.totalPages == nil)
let rangedPosition = BooksPageNavigationToken.position(description: "Page 69 of 701")
precondition(rangedPosition?.page == 69 && rangedPosition?.totalPages == 701)
for description in ["Page 0", "Page -1", "Page\t52", "Page 0 of 701", "Page 52 of 0", "Page 702 of 701", "Page 10000001", "Page 52 of 10000001", "Page 52 of 701 ", "Chapter Page 52", "Page ５２", "Page 52\u{0000}Hidden prose"] {
    precondition(BooksPageNavigationToken.parse(description: description) == nil)
    precondition(BooksPageNavigationToken.position(description: description) == nil)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-reader-check-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
try FileManager.default.createDirectory(at: root.appendingPathComponent("BKLibrary"), withIntermediateDirectories: true)
let epub = root.appendingPathComponent("fixture.epub")
try Data().write(to: epub)
var db: OpaquePointer?
precondition(sqlite3_open(root.appendingPathComponent("BKLibrary/BKLibrary-test.sqlite").path, &db) == SQLITE_OK)
defer { sqlite3_close(db) }
func execute(_ sql: String) { precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
let safePath = epub.path.replacingOccurrences(of: "'", with: "''")
execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT)")
execute("INSERT INTO ZBKLIBRARYASSET VALUES ('fixture-id','Synthetic Reading','Author','\(safePath)')")
let catalog = BooksCatalog(documents: root)
let match = try catalog.lookup(readerTitle: "Synthetic Reading")
precondition(match?.book.id == "apple-books:fixture-id" && match?.progress?.reliable == false)
let partial = try catalog.lookup(readerTitle: "Synthetic")
precondition(partial == nil)
execute("INSERT INTO ZBKLIBRARYASSET VALUES ('different-edition','Synthetic Reading','Author','\(safePath)')")
var rejected = false
do { _ = try catalog.lookup(readerTitle: "Synthetic Reading") } catch { rejected = true }
precondition(rejected)
execute("DELETE FROM ZBKLIBRARYASSET WHERE ZASSETID='different-edition'")
try FileManager.default.removeItem(at: epub)
let missing = try catalog.lookup(readerTitle: "Synthetic Reading")
precondition(missing == nil)
execute("ALTER TABLE ZBKLIBRARYASSET ADD COLUMN ZISFINISHED INTEGER")
execute("ALTER TABLE ZBKLIBRARYASSET ADD COLUMN ZDATEFINISHED REAL")
execute("UPDATE ZBKLIBRARYASSET SET ZISFINISHED=1,ZDATEFINISHED=700000000")
execute("INSERT INTO ZBKLIBRARYASSET (ZASSETID,ZTITLE,ZAUTHOR,ZISFINISHED) VALUES ('unknown','Unknown date','Author',1),('not-finished','Not finished','Author',0)")
let history = try catalog.finishedBooks(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
precondition(history.count == 2)
precondition(history.first { $0.book.id == "apple-books:fixture-id" }?.finishedAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
precondition(history.first { $0.book.id == "apple-books:unknown" }?.finishedAt == nil)
precondition(BooksCatalog.completionDate(referenceSeconds: 900_000_000, now: Date(timeIntervalSinceReferenceDate: 800_000_000)) == nil)
print("books-smoke: observed reader guards, unique stable identity, ambiguous editions and missing assets passed")
