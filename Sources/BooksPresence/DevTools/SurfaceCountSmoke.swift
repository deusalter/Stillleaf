import AppKit
import SwiftUI
import BooksCore

/// One screen or sheet and the glass surfaces it draws over the garden.
struct SurfaceMeasurement {
    enum Kind {
        /// A dashboard destination: the floating sidebar plus at most one content surface.
        case dashboard
        /// A sheet: it is the surface, so nothing inside it is glass.
        case sheet
        /// An onboarding step: at most one surface holding that step's choices.
        case onboarding
    }

    let name: String
    let kind: Kind
    let regions: [GlassRegion]

    /// Surfaces other than the sidebar.
    var content: [GlassRegion] {
        kind == .dashboard ? regions.filter { $0.frame.minX > DashboardView.sidebarWidth } : regions
    }

    var sidebar: [GlassRegion] {
        kind == .dashboard ? regions.filter { $0.frame.minX <= DashboardView.sidebarWidth } : []
    }

    /// Surfaces that sit entirely inside another one.
    var nested: [GlassRegion] {
        regions.filter { inner in
            regions.contains { outer in
                outer != inner && outer.frame.insetBy(dx: -0.5, dy: -0.5).contains(inner.frame)
            }
        }
    }

    var allowedContentSurfaces: Int { kind == .sheet ? 0 : 1 }

    /// What is wrong with this screen, or nil when it follows the rule.
    var violation: String? {
        if kind == .dashboard && sidebar.count != 1 { return "\(sidebar.count) sidebar surfaces, expected 1" }
        if content.count > allowedContentSurfaces { return "\(content.count) content surfaces, at most \(allowedContentSurfaces)" }
        if !nested.isEmpty { return "\(nested.count) surfaces nested inside another" }
        return nil
    }
}

@MainActor
private final class SurfaceBox { var regions: [GlassRegion] = [] }

/// Hosts a view the way the app does (a garden backdrop with named space) and returns the
/// glass regions it publishes for the garden to frost.
@MainActor
func publishedGlassRegions(of view: AnyView, size: NSSize, settle: TimeInterval = 0.6) -> [GlassRegion] {
    let box = SurfaceBox()
    let hosted = view
        .coordinateSpace(name: GardenCanvas.space)
        .environment(\.gardenBackdrop, true)
        .environment(\.nativePreviewOpaque, false)
        .onPreferenceChange(GlassRegionsKey.self) { box.regions = $0 }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let controller = NSHostingController(rootView: hosted)
    controller.sizingOptions = []
    window.contentViewController = controller
    window.setContentSize(size)
    defer { window.contentViewController = nil; window.contentView = nil; window.close() }
    controller.view.frame = NSRect(origin: .zero, size: size)
    controller.view.layoutSubtreeIfNeeded()
    // Screens such as History prepare their content off the main thread; wait for it to publish.
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    controller.view.layoutSubtreeIfNeeded()
    return box.regions
}

/// Counts the glass surfaces on every dashboard screen, sheet and onboarding step.
@MainActor
func measureGlassSurfaces(model: AppModel, emptyModel: AppModel) -> [SurfaceMeasurement] {
    let dashboardSize = NSSize(width: 1180, height: 820)
    var results: [SurfaceMeasurement] = []
    func dashboard(_ name: String, _ view: DashboardView, settle: TimeInterval = 0.6) {
        results.append(SurfaceMeasurement(name: name, kind: .dashboard,
            regions: publishedGlassRegions(of: AnyView(view), size: dashboardSize, settle: settle)))
    }
    dashboard("today", DashboardView(model: model, initialSection: .today))
    dashboard("today (empty)", DashboardView(model: emptyModel, initialSection: .today))
    dashboard("library", DashboardView(model: model, initialSection: .library))
    dashboard("library (empty)", DashboardView(model: emptyModel, initialSection: .library))
    dashboard("timeline", DashboardView(model: model, initialSection: .timeline))
    dashboard("timeline (empty)", DashboardView(model: emptyModel, initialSection: .timeline))
    for scale in CalendarScale.allCases {
        dashboard("history \(scale.rawValue)", DashboardView(model: model, initialSection: .history, initialCalendarScale: scale), settle: 1.5)
    }
    dashboard("reviews", DashboardView(model: model, initialSection: .review))
    dashboard("reviews (empty)", DashboardView(model: emptyModel, initialSection: .review))
    dashboard("data health", DashboardView(model: model, initialSection: .health))
    for category in SettingsCategory.allCases {
        dashboard("settings \(category.rawValue.lowercased())", DashboardView(model: model, initialSection: .settings, initialSettingsCategory: category))
    }

    func sheet(_ name: String, _ view: some View, size: NSSize) {
        results.append(SurfaceMeasurement(name: name, kind: .sheet,
            regions: publishedGlassRegions(of: AnyView(view), size: size)))
    }
    sheet("add reading time", ManualAdditionView(model: model), size: NSSize(width: 500, height: 600))
    sheet("read manually", ManualStartView(model: model), size: NSSize(width: 470, height: 350))
    if let book = model.books.first {
        sheet("book detail", BookDetailView(model: model, book: book), size: NSSize(width: 760, height: 720))
    }
    if let interval = model.displayIntervals.first {
        sheet("edit session", ReadingSessionEditor(model: model, interval: interval), size: NSSize(width: 560, height: 600))
    }
    sheet("troubleshooting", TrackingHelpView(model: model), size: NSSize(width: 740, height: 650))

    for step in OnboardingStep.allCases {
        results.append(SurfaceMeasurement(name: "onboarding \(step.rawValue + 1) \(step.title.lowercased())", kind: .onboarding,
            regions: publishedGlassRegions(of: AnyView(OnboardingView(model: emptyModel,
                flow: OnboardingFlow(model: emptyModel, step: step), finish: { _ in })), size: OnboardingView.size)))
    }
    return results
}

/// Every screen holds to "one glass surface per region". Fails with the offending screens.
@MainActor
func checkGlassSurfaceCounts(model: AppModel, emptyModel: AppModel) throws {
    let defaults = UserDefaults(suiteName: "BooksPresence.Surfaces.\(UUID().uuidString)")!
    // The garden must be on for glass to publish regions, whatever the developer's own choice.
    ThemeStore.shared.reload(from: defaults)
    ThemeStore.shared.select(garden: .still)
    defer { ThemeStore.shared.reload(from: .standard) }
    let measurements = measureGlassSurfaces(model: model, emptyModel: emptyModel)
    // A broken harness must not pass vacuously: every dashboard screen draws its sidebar.
    guard measurements.contains(where: { $0.kind == .dashboard && $0.content.count == 1 }) else {
        throw UISurfaceError.failed("Hosting the dashboard published no content surface, so the count proves nothing")
    }
    let violations = measurements.compactMap { measurement in measurement.violation.map { "\(measurement.name): \($0)" } }
    guard violations.isEmpty else {
        throw UISurfaceError.failed("Too many glass surfaces:\n  " + violations.joined(separator: "\n  "))
    }
    print("ui-smoke: each screen draws one glass surface per region (sidebar + one content surface), sheets none, onboarding steps one")
}

enum UISurfaceError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

/// `--render-ui <dir> --offscreen --surface-report`: prints the table the pull request quotes.
@MainActor
func printGlassSurfaceReport(model: AppModel, emptyModel: AppModel) {
    ThemeStore.shared.select(garden: .still)
    for measurement in measureGlassSurfaces(model: model, emptyModel: emptyModel) {
        let sidebar = measurement.kind == .dashboard ? " sidebar=\(measurement.sidebar.count)" : ""
        let status = measurement.violation.map { "FAIL \($0)" } ?? "ok"
        print("ui-surfaces: \(measurement.name): content=\(measurement.content.count)\(sidebar) nested=\(measurement.nested.count) \(status)")
    }
}
