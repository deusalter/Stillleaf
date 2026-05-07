import Foundation
import CSQLite
@testable import BooksPlatform

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
for description in ["Page 0", "Page -1", "Page\t52", "Page 52 of 300", "Chapter Page 52", "Page ５２", "Page 52\u{0000}Hidden prose"] {
    precondition(BooksPageNavigationToken.parse(description: description) == nil)
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
print("books-smoke: observed reader guards, unique stable identity, ambiguous editions and missing assets passed")
