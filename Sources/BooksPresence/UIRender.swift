import AppKit
import SwiftUI
import BooksCore

/// Renders only app-owned views with synthetic history; never captures the screen or the user's database.
@MainActor
func renderUIPreviews(to destination: URL) throws {
    if CommandLine.arguments.contains("--history-atlas") {
        try renderHistoryAtlasPreviews(to: destination)
        return
    }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("BooksPresence-preview-\(UUID().uuidString)")
    let suite = "BooksPresence.Preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("America/Los_Angeles", forKey: "timezoneID")
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
        ThemeStore.shared.reload(from: .standard)
    }
    // Previews always start from the default theme and never write the user's choice.
    ThemeStore.shared.reload(from: defaults)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try seedPreviewHistory(at: support)
    let model = try AppModel(support: support, defaults: defaults, startTracking: false)
    defer { model.shutdown() }
    let emptyModel = try AppModel(support: support.appendingPathComponent("empty"), defaults: defaults, startTracking: false)
    defer { emptyModel.shutdown() }
    let exceededSupport = support.appendingPathComponent("exceeded")
    try seedPreviewHistory(at: exceededSupport)
    let exceededStore = try ReadingStore(url: exceededSupport.appendingPathComponent("history.sqlite"))
    let now = Date()
    for index in 0..<3 {
        let start = now.addingTimeInterval(-40 + Double(index * 10))
        let interval = ReadingInterval(sessionID: "preview-goal-\(index)", bookID: "preview-waves", start: start,
                                       end: start.addingTimeInterval(8), duration: 8, timezoneID: "America/Los_Angeles", mode: .automatic)
        try exceededStore.appendInterval(interval)
        try exceededStore.appendEvent(AuditEvent(date: interval.end, kind: "pageTurn", bookID: interval.bookID,
            sessionID: interval.sessionID, detail: "Synthetic over-goal layout fixture.",
            pageTurn: PageTurnEvidence(fromPage: 100 + index * 8, toPage: 108 + index * 8,
                                        pagesRead: 8, visiblePages: 1, layoutSignature: "preview")))
    }
    let exceededModel = try AppModel(support: exceededSupport, defaults: defaults, startTracking: false)
    defer { exceededModel.shutdown() }
    let manualModel = try AppModel(support: support.appendingPathComponent("manual"), defaults: defaults, startTracking: false)
    manualModel.startManual(title: "A Room of One’s Own", author: "Virginia Woolf")
    defer { manualModel.shutdown() }
    let timeSupport = support.appendingPathComponent("minutes")
    try seedPreviewHistory(at: timeSupport)
    let timeModel = try AppModel(support: timeSupport, defaults: defaults, startTracking: false)
    defer { timeModel.shutdown() }
    timeModel.dailyGoalUnit = .minutes; timeModel.goalMinutes = 45; timeModel.annualBookGoal = 12
    timeModel.saveSettings()
    if let book = model.books.first {
        model.saveReview("What stayed with me was the quiet confidence of the ending.\n\nA story I would return to, with more to notice each time.", for: book.id)
    }
    emptyModel.discordEnabled = true
    emptyModel.discordApplicationID = ""
    for dark in [true, false] {
        let scheme: ColorScheme = dark ? .dark : .light
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        var previews: [(String, AnyView)] = []
        for scale in CalendarScale.allCases {
            previews.append(("history-\(scale.rawValue)", AnyView(DashboardView(model: model, initialSection: .history, initialCalendarScale: scale))))
        }
        for category in SettingsCategory.allCases {
            previews.append(("settings-\(category.rawValue.lowercased())", AnyView(DashboardView(model: model, initialSection: .settings, initialSettingsCategory: category))))
        }
        for section in [DashboardSection.today, .library, .timeline, .review, .health] {
            previews.append((section.rawValue, AnyView(DashboardView(model: model, initialSection: section))))
        }
        previews.append(("today-minutes", AnyView(DashboardView(model: timeModel))))
        previews.append(("settings-minutes", AnyView(DashboardView(model: timeModel, initialSection: .settings))))
        previews.append(("popover-minutes", AnyView(PopoverView(model: timeModel))))
        previews.append(("popover", AnyView(PopoverView(model: exceededModel))))
        previews.append(("popover-manual", AnyView(PopoverView(model: manualModel))))
        previews.append(("popover-setup", AnyView(PopoverView(model: emptyModel, maximumHeight: 500))))
        previews.append(("today-empty", AnyView(DashboardView(model: emptyModel))))
        for step in OnboardingStep.allCases {
            previews.append(("onboarding-\(step.rawValue + 1)", AnyView(OnboardingView(model: emptyModel,
                flow: OnboardingFlow(model: emptyModel, step: step), finish: { _ in }))))
        }
        previews.append(("today-exceeded", AnyView(DashboardView(model: exceededModel))))
        if let entry = model.finishedBooks.first {
            previews.append(("finished-prompt", AnyView(FinishedBookPrompt(model: model, entry: entry))))
            previews.append(("finished-timeline", AnyView(ScrollView { FinishedBookTimeline(model: model).padding(24) }.background(ReadingPalette.paper))))
        }
        if let book = model.books.first {
            previews.append(("book-detail", AnyView(BookDetailView(model: model, book: book))))
            previews.append(("written-review", AnyView(BookReviewEditor(model: model, bookID: book.id))))
        }
        previews.append(("troubleshooting", AnyView(TrackingHelpView(model: model))))
        previews.append(("reading-calendar", AnyView(ReadingDateCalendar(selection: .constant(now),
            timezoneID: model.timezoneID).padding(24).frame(width: 450).background(ReadingPalette.paper))))
        previews.append(("reading-dates", AnyView(ReadingDatesEditor(title: "A Room of One’s Own",
            dates: ReadingCompletionDates(finishedAt: now), timezoneID: model.timezoneID, save: { _ in nil }))))
        previews.append(("reading-dates-expanded", AnyView(ReadingDatesEditor(title: "A Room of One’s Own",
            dates: ReadingCompletionDates(finishedAt: now), timezoneID: model.timezoneID,
            initiallyExpanded: true, save: { _ in nil }))))
        previews.append(("rating-quarter", AnyView(RatingPreview(value: 4.25))))
        previews.append(("rating-zero", AnyView(RatingPreview(value: 0))))
        previews.append(("rating-empty", AnyView(RatingPreview(value: nil))))
        previews.append(("manual-start", AnyView(ManualStartView(model: model))))
        previews.append(("manual-add", AnyView(ManualAdditionView(model: model))))
        if let interval = model.displayIntervals.first {
            previews.append(("review-editor", AnyView(IntervalReviewEditor(model: model, interval: interval))))
        }
        for (name, view) in previews {
            let view = view.environment(\.colorScheme, scheme)
            let sizes: [String: NSSize] = ["reading-calendar": NSSize(width: 450, height: 410),
                "reading-dates": NSSize(width: 540, height: 500),
                "reading-dates-expanded": NSSize(width: 540, height: 760),
"manual-start": NSSize(width: 470, height: 350),
                "manual-add": NSSize(width: 500, height: 510), "review-editor": NSSize(width: 560, height: 600),
                "book-detail": NSSize(width: 760, height: 720), "troubleshooting": NSSize(width: 740, height: 650),
                "rating-quarter": NSSize(width: 320, height: 200), "rating-zero": NSSize(width: 320, height: 200), "rating-empty": NSSize(width: 320, height: 200),
                "written-review": NSSize(width: 590, height: 540), "popover-minutes": NSSize(width: 350, height: 580),
                "popover": NSSize(width: 350, height: 580), "popover-manual": NSSize(width: 350, height: 580),
                "popover-setup": NSSize(width: 350, height: 500)]
            try renderNativeView(AnyView(view), size: name.hasPrefix("onboarding-") ? OnboardingView.size : sizes[name] ?? NSSize(width: 1180, height: 820), appearance: appearance,
                                 to: destination.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        let compact = DashboardView(model: model, initialSection: .history).environment(\.colorScheme, scheme)
        try renderNativeView(AnyView(compact), size: NSSize(width: 920, height: 660), appearance: appearance,
                             to: destination.appendingPathComponent("history-compact-\(dark ? "dark" : "light").png"))
        let compactTimeline = DashboardView(model: model, initialSection: .timeline).environment(\.colorScheme, scheme)
        try renderNativeView(AnyView(compactTimeline), size: NSSize(width: 920, height: 660), appearance: appearance,
                             to: destination.appendingPathComponent("timeline-compact-\(dark ? "dark" : "light").png"))
        let compactToday = DashboardView(model: exceededModel).environment(\.colorScheme, scheme)
        try renderNativeView(AnyView(compactToday), size: NSSize(width: 920, height: 660), appearance: appearance,
                             to: destination.appendingPathComponent("today-compact-\(dark ? "dark" : "light").png"))
    }
    if CommandLine.arguments.contains("--all-themes") {
        try renderThemePreviews(model: model, to: destination.appendingPathComponent("themes", isDirectory: true))
    }
    try renderProgressMotion(model: exceededModel, to: destination)
    try renderRatingMotion(to: destination)
    try renderCompletionMotion(to: destination)
    print("ui-render: synthetic light/dark native previews saved to \(destination.path)")
}

@MainActor
func renderNativeView(_ view: AnyView, size: NSSize, appearance: NSAppearance?, settle: TimeInterval = 0.45, to output: URL) throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = appearance
    window.contentView = hosting
    window.orderBack(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(settle))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    // Detach the SwiftUI tree so closed previews stop observing the model and theme store.
    defer { window.contentView = nil; window.close() }
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw UIPreviewError.renderFailed
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
    try data.write(to: output, options: .atomic)
}

private func seedPreviewHistory(at support: URL) throws {
    let store = try ReadingStore(url: support.appendingPathComponent("history.sqlite"))
    let books = [BookRecord(id: "preview-waves", title: "The Waves", author: "Virginia Woolf"),
                 BookRecord(id: "preview-walden", title: "Walden", author: "Henry David Thoreau"),
                 BookRecord(id: "preview-rooms", title: "A Room of One’s Own", author: "Virginia Woolf"),
                 BookRecord(id: "preview-garden", title: "The Secret Garden", author: "Frances Hodgson Burnett"),
                 BookRecord(id: "preview-journey", title: "A Journey to the Centre of the Earth", author: "Jules Verne"),
                 BookRecord(id: "preview-night", title: "Notes from a Quiet Night"),
                 BookRecord(id: "preview-sea", title: "The Sea and the Mirror", author: "W. H. Auden"),
                 BookRecord(id: "preview-orchard", title: "The Orchard", author: "A very long author name for a narrow shelf")]
    for book in books { try store.saveBook(book) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let today = calendar.startOfDay(for: Date())
    for offset in 1...65 where offset % 5 != 0 {
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        let start = calendar.date(bySettingHour: 19, minute: offset % 3 * 10, second: 0, of: date)!
        let duration = Double(12 + (offset * 13) % 48) * 60
        let book = books[offset % books.count]
        let mode: ReadingMode = offset % 4 == 0 ? .manual : .automatic
        let disposition: IntervalDisposition = offset % 13 == 0 ? .uncertain : .credited
        let interval = ReadingInterval(sessionID: "preview-session-\(offset)", bookID: book.id,
                                       start: start, end: start.addingTimeInterval(duration), duration: duration,
                                       timezoneID: calendar.timeZone.identifier, mode: mode, disposition: disposition)
        try store.appendInterval(interval)
        if mode == .automatic, disposition == .credited {
            let visiblePages = offset % 3 == 0 ? 2 : 1
            let fromPage = 20 + offset * 3
            try store.appendEvent(AuditEvent(id: "preview-page-\(offset)", date: interval.end, kind: "pageTurn", bookID: book.id,
                                             sessionID: interval.sessionID, detail: "Synthetic adjacent visible pages.",
                                             pageTurn: PageTurnEvidence(fromPage: fromPage, toPage: fromPage + visiblePages,
                                                                         pagesRead: visiblePages, visiblePages: visiblePages,
                                                                         layoutSignature: "preview-\(visiblePages)-up")))
        }
    }
    let end = Date().addingTimeInterval(-60)
    let start = max(today, end.addingTimeInterval(-1680))
    if end > start {
        try store.appendInterval(ReadingInterval(sessionID: "preview-today", bookID: books[0].id,
                                                start: start, end: end, duration: end.timeIntervalSince(start),
                                                timezoneID: calendar.timeZone.identifier, mode: .manual))
    }
    let earlierEnd = end.addingTimeInterval(-1800)
    let earlierStart = max(today, earlierEnd.addingTimeInterval(-900))
    if earlierEnd > earlierStart {
        let interval = ReadingInterval(sessionID: "preview-today-earlier", bookID: books[1].id,
                                       start: earlierStart, end: earlierEnd, duration: earlierEnd.timeIntervalSince(earlierStart),
                                       timezoneID: calendar.timeZone.identifier, mode: .automatic)
        try store.appendInterval(interval)
        try store.appendEvent(AuditEvent(id: "preview-page-today", date: interval.end, kind: "pageTurn", bookID: books[1].id,
                                         sessionID: interval.sessionID, detail: "Synthetic adjacent visible pages.",
                                         pageTurn: PageTurnEvidence(fromPage: 40, toPage: 42, pagesRead: 2, visiblePages: 2,
                                                                     layoutSignature: "preview-2-up")))
    }
    try store.setGoal(GoalChange(effectiveDay: ReadingStatistics.dayKey(calendar.date(byAdding: .day, value: -90, to: today)!, timezoneID: calendar.timeZone.identifier), minutes: 20, pages: 8))
    try store.appendEvent(AuditEvent(id: "preview-finished-waves", date: today.addingTimeInterval(-3 * 86_400), kind: "bookCompleted", bookID: books[0].id,
                                     detail: "Synthetic Apple Books completion metadata.",
                                     completion: BookCompletionEvidence(finishedAt: today.addingTimeInterval(-3 * 86_400), source: "Apple Books", imported: true)))
    try store.appendEvent(AuditEvent(id: "preview-rating-waves", date: today.addingTimeInterval(-3 * 86_400 + 10), kind: "bookRated", bookID: books[0].id,
                                     detail: "Synthetic reader rating.", rating: BookRatingEvidence(value: 4.25)))
    try store.appendEvent(AuditEvent(id: "preview-finished-walden", date: today.addingTimeInterval(-86_400), kind: "bookCompleted", bookID: books[1].id,
                                     detail: "Synthetic Apple Books completion metadata.",
                                     completion: BookCompletionEvidence(finishedAt: today.addingTimeInterval(-86_400), source: "Apple Books", imported: true)))
    try store.appendEvent(AuditEvent(id: "preview-rating-walden", date: today.addingTimeInterval(-86_400 + 10), kind: "bookRated", bookID: books[1].id,
                                     detail: "Synthetic reader rating.", rating: BookRatingEvidence(value: 0)))
}

private enum UIPreviewError: Error { case renderFailed }

/// Every dashboard screen and the popover in every theme, light and dark:
/// `<dir>/themes/<theme>/<screen>-<light|dark>.png`.
@MainActor
private func renderThemePreviews(model: AppModel, to destination: URL) throws {
    let store = ThemeStore.shared
    defer { store.select(theme: ReadingTheme.all[0].id) }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    // Live switch: the same window stays open while the theme changes, as when a person uses the picker.
    for (section, category) in [(DashboardSection.settings, SettingsCategory.appearance), (.today, .reading)] {
        store.select(theme: ReadingTheme.all[0].id)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: DashboardView(model: model, initialSection: section, initialSettingsCategory: category)
            .environment(\.colorScheme, .light))
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        store.select(theme: "plum")
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw UIPreviewError.renderFailed }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("live-switch-\(section.rawValue).png"))
        window.contentView = nil
        window.close()
    }
    for theme in ReadingTheme.all {
        store.select(theme: theme.id)
        let folder = destination.appendingPathComponent(theme.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            var screens: [(String, AnyView, NSSize)] = [
                ("today", AnyView(DashboardView(model: model)), NSSize(width: 1180, height: 820)),
                ("library", AnyView(DashboardView(model: model, initialSection: .library)), NSSize(width: 1180, height: 820)),
                ("timeline", AnyView(DashboardView(model: model, initialSection: .timeline)), NSSize(width: 1180, height: 820)),
                ("history-month", AnyView(DashboardView(model: model, initialSection: .history, initialCalendarScale: .month)), NSSize(width: 1180, height: 820)),
                ("history-day", AnyView(DashboardView(model: model, initialSection: .history, initialCalendarScale: .day)), NSSize(width: 1180, height: 820)),
                ("review", AnyView(DashboardView(model: model, initialSection: .review)), NSSize(width: 1180, height: 820)),
                ("settings-reading", AnyView(DashboardView(model: model, initialSection: .settings, initialSettingsCategory: .reading)), NSSize(width: 1180, height: 820)),
                ("settings-appearance", AnyView(DashboardView(model: model, initialSection: .settings, initialSettingsCategory: .appearance)), NSSize(width: 1180, height: 820)),
                ("health", AnyView(DashboardView(model: model, initialSection: .health)), NSSize(width: 1180, height: 820)),
                ("popover", AnyView(PopoverView(model: model)), NSSize(width: 350, height: 580))
            ]
            // The first fresh window after a theme switch can be captured mid-entrance offscreen;
            // a discarded warm-up render absorbs it so every saved preview is fully settled.
            try renderNativeView(AnyView(DashboardView(model: model).environment(\.colorScheme, dark ? .dark : .light)),
                                 size: NSSize(width: 1180, height: 820), appearance: appearance, settle: 1.2,
                                 to: FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-theme-warmup.png"))
            if let book = model.books.first {
                screens.append(("book-detail", AnyView(BookDetailView(model: model, book: book)), NSSize(width: 760, height: 720)))
            }
            for (name, view, size) in screens {
                // A theme switch re-keys the dashboard; let its entrance and first split-view layout finish.
                try renderNativeView(AnyView(view.environment(\.colorScheme, dark ? .dark : .light)), size: size, appearance: appearance,
                                     settle: 1.2, to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

/// Samples the actual animated overview at three points in its entrance. These
/// app-owned frames help inspect motion without screen recording or live history.
@MainActor
private func renderProgressMotion(model: AppModel, to destination: URL) throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 310),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    let hosting = NSHostingView(rootView: DailyReadingOverview(model: model)
        .environment(\.colorScheme, .light).foregroundStyle(ReadingPalette.ink)
        .padding(6).frame(width: 850, height: 310).background(ReadingPalette.paper))
    window.contentView = hosting
    window.orderBack(nil)
    let started = Date()
    hosting.layoutSubtreeIfNeeded()
    defer { window.close() }
    for (name, time) in [("start", 0.01), ("middle", 0.14), ("end", 0.45)] {
        RunLoop.current.run(until: started.addingTimeInterval(time))
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw UIPreviewError.renderFailed }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
        try data.write(to: destination.appendingPathComponent("progress-motion-\(name).png"), options: .atomic)
    }
}

private struct RatingPreview: View {
    @State var value: Double?
    var body: some View {
        QuarterStarRating(rating: $value).padding(24)
            .frame(width: 320, height: 200)
            .foregroundStyle(ReadingPalette.ink).background(ReadingPalette.paper)
    }
}

@MainActor
private final class RatingMotionState: ObservableObject {
    @Published var rating: Double? = 0
}
private struct RatingMotionPreview: View {
    @ObservedObject var state: RatingMotionState
    var body: some View {
        QuarterStarRating(rating: $state.rating).padding(24)
            .frame(width: 320, height: 200)
            .foregroundStyle(ReadingPalette.ink).background(ReadingPalette.paper)
    }
}
/// Native transition samples use isolated draft state and never save a user rating.
@MainActor
private func renderRatingMotion(to destination: URL) throws {
    do {
        let state = RatingMotionState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: RatingMotionPreview(state: state)
            .environment(\.colorScheme, .light))
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        state.rating = 4.25
        let started = Date()
        for (name, time) in [("start", 0.01), ("middle", 0.07), ("end", 0.25)] {
            RunLoop.current.run(until: started.addingTimeInterval(time))
            hosting.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw UIPreviewError.renderFailed }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
            try data.write(to: destination.appendingPathComponent("rating-motion-normal-\(name).png"), options: .atomic)
        }
        window.close()
    }
}

/// Samples the real badge task in a native host. These frames verify states,
/// not display refresh pacing or input-to-render latency.
@MainActor
private func renderCompletionMotion(to destination: URL) throws {
    for reduced in [false, true] {
        var claims = 0
        let badge = CompletionCelebrationBadge(forceReducedMotion: reduced, eventID: "synthetic-completion") {
            claims += 1
            return claims == 1
        }
        .frame(width: 100, height: 100)
        .background(ReadingPalette.paper)
        .environment(\.colorScheme, .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: badge)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        let started = Date()
        for (name, time) in [("start", 0.02), ("middle", 0.25), ("end", 0.9)] {
            RunLoop.current.run(until: started.addingTimeInterval(time))
            hosting.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw UIPreviewError.renderFailed }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw UIPreviewError.renderFailed }
            try data.write(to: destination.appendingPathComponent("completion-motion-\(reduced ? "reduced" : "normal")-\(name).png"), options: .atomic)
        }
        guard claims == 1 else { throw UIPreviewError.renderFailed }
        window.close()
    }
}
