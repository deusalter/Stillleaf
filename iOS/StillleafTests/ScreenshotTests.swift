import XCTest
import SwiftUI
import UIKit
import BooksCore
@testable import Stillleaf

/// Captures every screen with generated books, for review. It runs only when a capture folder exists:
/// `STILLLEAF_SCREENSHOTS`, or `/tmp/stillleaf-ios-screenshots` (the simulator shares the host's files).
/// For each screen the test writes `<name>.request` and iOS/scripts/ci-build-and-test.sh answers with a real
/// simulator screenshot, so the web page, sheets and system bars are all in the picture. With no host
/// listening it draws the window itself.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow!
    private var hostCaptures = true
    private var captured = 0

    func testCaptureEveryScreen() async throws {
        let named = ProcessInfo.processInfo.environment["STILLLEAF_SCREENSHOTS"] ?? "/tmp/stillleaf-ios-screenshots"
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: named, isDirectory: &isFolder), isFolder.boolValue else {
            throw XCTSkip("No capture folder; screenshots are taken in CI.")
        }
        folder = URL(fileURLWithPath: named, isDirectory: true)
        let standard = UserDefaults.standard
        let welcomed = standard.object(forKey: "welcomeCompleted")
        standard.set(true, forKey: "welcomeCompleted")
        standard.removeObject(forKey: ReaderChrome.defaultsKey)
        defer {
            standard.set(welcomed, forKey: "welcomeCompleted")
            standard.removeObject(forKey: ReaderChrome.defaultsKey)
            window?.isHidden = true
        }

        let scratch = try Scratch()
        let journal = try scratch.journal()
        let books = try await seed(journal, scratch)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1

        // The app's tabs.
        let router = AppRouter()
        show(RootView(router: router).environmentObject(journal))
        try await capture("01-reading-now", settle: 2)
        router.tab = .library
        try await capture("02-library")
        router.tab = .journal
        try await capture("03-journal-calendar")
        router.journalMode = .finished
        try await capture("04-journal-finished")
        router.journalMode = .reviews
        try await capture("05-journal-reviews")
        router.journalMode = .calendar
        router.tab = .reading
        router.sheet = .settings
        try await capture("06-settings", settle: 1.4)
        router.sheet = nil
        try await Task.sleep(nanoseconds: 900_000_000)
        router.sheet = .logReading
        try await capture("07-log-reading", settle: 1.4)
        router.sheet = nil
        try await Task.sleep(nanoseconds: 900_000_000)

        window.overrideUserInterfaceStyle = .dark
        try await capture("08-reading-now-dark")
        router.tab = .library
        try await capture("09-library-dark")
        window.overrideUserInterfaceStyle = .unspecified

        show(NavigationStack { BookDetailView(bookID: books[0]) }.environmentObject(journal).environmentObject(router))
        try await capture("10-book-detail")

        // The reader, its controls and sheets.
        let edition = try XCTUnwrap(journal.edition(forBook: books[0]))
        let chrome = ReaderChrome()
        var closed = false
        show(ReaderScreen(edition: edition, journal: journal, chrome: chrome) { closed = true }.environmentObject(journal))
        try await waitUntil("the reader's controls to connect", timeout: 120) { chrome.connected }
        try await capture("11-reader-first-page", settle: 3)
        for _ in 0..<4 {
            _ = try await chrome.transport?("next", nil)
            try await Task.sleep(nanoseconds: 900_000_000)
        }
        try await capture("12-reader-page", settle: 1.5)
        chrome.toggleControls()
        try await capture("13-reader-controls")
        chrome.open(.contents)
        try await waitUntil("the contents rows", timeout: 20) { !(chrome.lists[.outline]?.rows.isEmpty ?? true) }
        try await capture("14-reader-contents", settle: 1.4)
        chrome.sheet = nil
        try await Task.sleep(nanoseconds: 900_000_000)
        chrome.open(.appearance)
        try await capture("15-reader-themes", settle: 1.4)
        if let night = chrome.control("theme")?.options?.first(where: { $0.value == "\"night\"" }) {
            chrome.choose(night, for: "theme")
            try await waitUntil("the night theme", timeout: 20) { chrome.pageIsDark }
            try await capture("16-reader-themes-night", settle: 1.6)
        }
        chrome.sheet = nil
        try await capture("17-reader-night", settle: 1.4)
        chrome.toggleControls()
        try await capture("18-reader-night-controls")
        chrome.searchQuery = "evening light"
        chrome.open(.search)
        try await waitUntil("search results", timeout: 30) { !chrome.search.rows.isEmpty }
        try await capture("19-reader-search", settle: 1.4)
        chrome.sheet = nil
        try await Task.sleep(nanoseconds: 900_000_000)
        chrome.close?()
        try await waitUntil("the reader to close", timeout: 30) { closed }

        // A new install.
        let emptyScratch = try Scratch()
        let empty = try emptyScratch.journal()
        let fresh = AppRouter()
        show(RootView(router: fresh).environmentObject(empty))
        try await capture("20-empty-reading-now", settle: 1.5)
        fresh.tab = .library
        try await capture("21-empty-library")
        fresh.tab = .reading
        standard.set(false, forKey: "welcomeCompleted")
        try await capture("22-welcome", settle: 1.6)
        standard.set(true, forKey: "welcomeCompleted")
        XCTAssertGreaterThanOrEqual(captured, 20)
    }

    // MARK: - Capture

    private func show<Content: View>(_ view: Content) {
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    private func capture(_ name: String, settle: Double = 1) async throws {
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let image = folder.appendingPathComponent(name + ".png")
        if hostCaptures {
            let request = folder.appendingPathComponent(name + ".request")
            try Data().write(to: request)
            let deadline = Date().addingTimeInterval(captured == 0 ? 15 : 40)
            while FileManager.default.fileExists(atPath: request.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if FileManager.default.fileExists(atPath: image.path) { captured += 1; return }
            try? FileManager.default.removeItem(at: request)
            hostCaptures = false
        }
        let bounds = window.bounds
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in window.drawHierarchy(in: bounds, afterScreenUpdates: true) }
        try png.write(to: image)
        captured += 1
    }

    // MARK: - Generated library

    private struct Sample {
        let title: String
        let author: String
        let top: UIColor
        let bottom: UIColor
        var chapters = 3
        var paragraphs = 24
    }

    /// Six generated books with a fortnight of reading: a streak, a goal in progress today, positions,
    /// two finished books and a review. Returns their journal IDs in order.
    private func seed(_ journal: Journal, _ scratch: Scratch) async throws -> [String] {
        let samples = [
            Sample(title: "The Quiet Orchard", author: "Mara Ellison", top: UIColor(red: 0.16, green: 0.36, blue: 0.30, alpha: 1), bottom: UIColor(red: 0.07, green: 0.20, blue: 0.17, alpha: 1), chapters: 9, paragraphs: 60),
            Sample(title: "Salt and Lanterns", author: "Idris Vane", top: UIColor(red: 0.15, green: 0.24, blue: 0.45, alpha: 1), bottom: UIColor(red: 0.06, green: 0.10, blue: 0.24, alpha: 1)),
            Sample(title: "A Winter Almanac", author: "Corin Hale", top: UIColor(red: 0.55, green: 0.18, blue: 0.20, alpha: 1), bottom: UIColor(red: 0.30, green: 0.08, blue: 0.12, alpha: 1)),
            Sample(title: "Letters to the Tide", author: "Noor Abadi", top: UIColor(red: 0.10, green: 0.45, blue: 0.50, alpha: 1), bottom: UIColor(red: 0.05, green: 0.24, blue: 0.30, alpha: 1)),
            Sample(title: "The Glass Meridian", author: "Tomas Reyes", top: UIColor(red: 0.78, green: 0.58, blue: 0.22, alpha: 1), bottom: UIColor(red: 0.52, green: 0.33, blue: 0.10, alpha: 1)),
            Sample(title: "Small Hours", author: "June Okafor", top: UIColor(red: 0.36, green: 0.22, blue: 0.45, alpha: 1), bottom: UIColor(red: 0.17, green: 0.10, blue: 0.26, alpha: 1))
        ]
        var ids: [String] = []
        for (index, sample) in samples.enumerated() {
            var entries = SyntheticEPUB.book(title: sample.title, author: sample.author, chapters: sample.chapters, paragraphs: sample.paragraphs)
            if let cover = entries.firstIndex(where: { $0.path == "EPUB/cover.png" }) { entries[cover].data = Self.cover(sample) }
            let imported = await journal.importEPUBs([try scratch.epub("book-\(index).epub", entries: entries)])
            ids.append(try XCTUnwrap(imported.first, journal.notice?.message ?? "import failed"))
        }
        journal.toast = nil
        XCTAssertTrue(journal.saveGoals(unit: .pages, pages: 20, minutes: 30, annualBooks: 24), journal.notice?.message ?? "")

        let calendar = Calendar.current
        let now = Date()
        func evening(_ daysAgo: Int, hour: Int = 21) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 10, second: 0, of: day) ?? day
        }
        func log(_ id: String, _ end: Date, minutes: Int, pages: Int) throws {
            let book = try XCTUnwrap(journal.book(id))
            XCTAssertTrue(journal.logReading(book: book, end: end, minutes: minutes, pages: pages), journal.notice?.message ?? "")
        }
        // Older reading, with a gap, then six days in a row and part of today's goal.
        try log(ids[5], evening(16), minutes: 50, pages: 38)
        try log(ids[5], evening(15), minutes: 42, pages: 30)
        try log(ids[4], evening(12), minutes: 35, pages: 26)
        try log(ids[4], evening(10), minutes: 12, pages: 8)
        try log(ids[2], evening(9), minutes: 28, pages: 21)
        for (daysAgo, pages) in [(6, 22), (5, 31), (4, 20), (3, 27), (2, 24), (1, 36)] {
            try log(ids[daysAgo % 2 == 0 ? 0 : 1], evening(daysAgo), minutes: pages + 8, pages: pages)
        }
        try log(ids[0], now.addingTimeInterval(-600), minutes: 16, pages: 12)

        func place(_ id: String, _ fraction: Double, _ location: String) {
            journal.readerOpened(bookID: id)
            journal.readerMoved(ProgressObservation(bookID: id, fraction: fraction, location: location, source: "stillleaf-reader", reliable: true))
            journal.readerClosed(bookID: id)
        }
        place(ids[0], 0.42, "Chapter 4")
        place(ids[1], 0.18, "Chapter 1")
        place(ids[2], 0.71, "Chapter 3")

        XCTAssertTrue(journal.markFinished(ids[5], at: evening(15)))
        XCTAssertTrue(journal.saveRating(4.5, for: ids[5]))
        XCTAssertTrue(journal.saveReview("Slow and exact. The night-shift chapters stayed with me for days, and the ending earns its quiet.", for: ids[5]))
        XCTAssertTrue(journal.markFinished(ids[4], at: evening(10)))
        XCTAssertTrue(journal.saveRating(4, for: ids[4]))
        journal.notice = nil
        return ids
    }

    /// A plain typographic cover in the sample's colours.
    private static func cover(_ sample: Sample) -> Data {
        let size = CGSize(width: 600, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let colours = [sample.top.cgColor, sample.bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor.white.withAlphaComponent(0.55).setStroke()
            let frame = UIBezierPath(rect: CGRect(x: 36, y: 36, width: size.width - 72, height: size.height - 72))
            frame.lineWidth = 2
            frame.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 6
            let serif = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title1).withDesign(.serif)
            let titleFont = UIFont(descriptor: serif ?? UIFontDescriptor(), size: 68)
            let title = NSAttributedString(string: sample.title, attributes: [
                .font: titleFont, .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            title.draw(with: CGRect(x: 80, y: 190, width: size.width - 160, height: 420), options: [.usesLineFragmentOrigin], context: nil)
            let author = NSAttributedString(string: sample.author.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph, .kern: 3])
            author.draw(with: CGRect(x: 60, y: 740, width: size.width - 120, height: 60), options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}
