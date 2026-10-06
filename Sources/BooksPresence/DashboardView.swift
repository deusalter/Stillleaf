import SwiftUI
import AppKit
import BooksCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: DashboardSection
    private let initialCalendarScale: CalendarScale
    private let initialSettingsCategory: SettingsCategory

    init(model: AppModel, initialSection: DashboardSection = .today, initialCalendarScale: CalendarScale = .month, initialSettingsCategory: SettingsCategory = .reading) {
        self.model = model
        _section = State(initialValue: initialSection)
        self.initialCalendarScale = initialCalendarScale
        self.initialSettingsCategory = initialSettingsCategory
    }
    @State private var sheet: DashboardSheet?
    @StateObject private var settingsDrafts = SettingsDraftStore()
    @StateObject private var libraryBrowsing = LibraryBrowseState()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var deleteAllConfirmation = false
    @State private var uninstallConfirmation = false
    @State private var sidebarVisible = true
    /// Height of the error banner above the page, which pushes the header (and so the clearing) down.
    @State private var bannerHeight: CGFloat = 0
    /// Glass panel frames for the garden to frost; a class so scrolling only redraws the garden.
    @State private var frost = FrostRegions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion

    var body: some View {
        // The garden runs under the whole window, title bar included; the
        // sidebar floats on it as a glass panel, as in the approved mockup.
        HStack(spacing: 0) {
            if sidebarVisible {
                DashboardSidebar(selection: $section, model: model, troubleshoot: { sheet = .trackingHelp })
                    .id(theme.revision)
                    .padding(.top, 34)
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .glassSurface(cornerRadius: ReadingMetrics.Radius.window)
                    .background(DashboardSidebarProbe())
                    .padding(10)
                    .ignoresSafeArea(edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                if let error = model.errorMessage ?? model.trackingRecoveryMessage, !error.isEmpty {
                    ErrorBanner(message: error, refresh: { model.refresh() })
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ErrorBannerHeightKey.self, value: proxy.size.height)
                        })
                }
                Group {
                    switch section {
                    case .today: TodayView(model: model, present: { sheet = $0 })
                    case .history: HistoryView(model: model, initialScale: initialCalendarScale)
                    case .library: LibraryView(model: model, present: { sheet = $0 }, browsing: libraryBrowsing)
                    case .review: PersonalReviewsView(model: model)
                    case .timeline: ReadingTimelineView(model: model, present: { sheet = $0 })
                    case .health: HealthView(model: model)
                    case .settings: SettingsView(model: model, present: { sheet = $0 }, deleteAll: { deleteAllConfirmation = true }, uninstall: { uninstallConfirmation = true }, initialCategory: model.settingsCategoryRequest ?? initialSettingsCategory, drafts: settingsDrafts)
                        .id(model.settingsCategoryRequest)
                    }
                }
                // A theme change re-keys only the rendered content, inside the entrance, so it
                // swaps instantly instead of replaying the fade. Settings re-keys its
                // rendered content while the dashboard retains its unsaved drafts.
                .id(Self.contentKey(for: section, revision: theme.revision))
                .readingEntrance()
                .id(section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(ReadingPalette.ink)
            .buttonStyle(ReadingButtonStyle())
        }
        .background {
            GeometryReader { proxy in
                ZStack {
                    ReadingPalette.canvas
                    // The garden stays put behind scrolling content. Screens adopt it
                    // once all their text sits on glass.
                    if gardenVisible {
                        let clearing = Self.gardenClearingHeight(safeTop: proxy.safeAreaInsets.top, section: section, bannerHeight: bannerHeight)
                        GardenCanvas(layout: GardenLayout(clearingHeight: clearing,
                                                          seed: GardenSeed.daily("dashboard", day: model.today.day),
                                                          pollenScale: section == .history ? 0.5 : 1),
                                     mode: gardenMode, frost: frost, frostOffset: proxy.safeAreaInsets.top)
                            .preference(key: GardenClearingKey.self, value: clearing)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .coordinateSpace(name: GardenCanvas.space)
        .environment(\.gardenBackdrop, gardenVisible)
        .onPreferenceChange(GlassRegionsKey.self) { frost.rects = $0 }
        .onPreferenceChange(ErrorBannerHeightKey.self) { bannerHeight = $0 }
        .nativeDashboardSidebarToggle(isCollapsed: !sidebarVisible) {
            withAnimation((previewReduceMotion ?? reduceMotion) ? nil : ReadingMotion.selection) {
                sidebarVisible.toggle()
            }
        }
        .readingMotionAccessibility()
        .onAppear { acceptNavigationRequest() }
        .onChange(of: model.dashboardSectionRequest) { _ in acceptNavigationRequest() }
        .frame(minWidth: 920, minHeight: 660)
        .toggleStyle(.switch)
        .tint(ReadingPalette.accent)
        .sheet(item: $sheet) { item in
            dashboardSheet(item).buttonStyle(ReadingButtonStyle()).readingMotionAccessibility()
                .environment(\.gardenBackdrop, false)
        }
        .alert("Delete all reading data?", isPresented: $deleteAllConfirmation) {
            Button("Delete all data", role: .destructive) { model.deleteAllData() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes local reading records, managed backups, and cached covers. Exports and backups you saved elsewhere are not removed; keep those yourself if needed.")
        }
        .alert("Uninstall Stillleaf?", isPresented: $uninstallConfirmation) {
            Button("Uninstall", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This disables startup and moves the installed app to Trash. Your local reading history remains. Use Delete all reading data to remove managed history, backups, and cached covers.")
        }
    }

    static let sidebarWidth: CGFloat = 225

    /// Screens whose text all sits on glass, so the garden can grow behind them.
    static let gardenSections = Set(DashboardSection.allCases)
    /// The resting height of a page header: top inset, title and subtitle.
    /// History adds its period title and summary line (84 pt) to that.
    static let gardenClearing: CGFloat = 114

    /// How far down from the window's top the garden keeps clear: the safe area, the page header
    /// and any error banner above it.
    static func gardenClearingHeight(safeTop: CGFloat, section: DashboardSection, bannerHeight: CGFloat) -> CGFloat {
        let historyHeader: CGFloat = section == .history ? 84 : 0
        return safeTop + gardenClearing + historyHeader + bannerHeight
    }

    private var gardenMode: GardenMode { theme.effectiveGardenMode(reduceMotion: previewReduceMotion ?? reduceMotion) }
    private var gardenVisible: Bool { Self.gardenSections.contains(section) && gardenMode != .off }

    /// Identity of the rendered screen for a theme revision. Settings keeps one identity
    /// because it owns unsaved drafts; every other screen re-keys so colours re-resolve.
    static func contentKey(for section: DashboardSection, revision: Int) -> String {
        section == .settings ? "settings" : "content-\(revision)"
    }

    private func acceptNavigationRequest() {
        guard let requested = model.dashboardSectionRequest else { return }
        section = requested
        model.dashboardSectionRequest = nil
    }

    @ViewBuilder
    private func dashboardSheet(_ sheet: DashboardSheet) -> some View {
        switch sheet {
        case .manualStart:
            ManualStartView(model: model)
        case .manualAdd:
            ManualAdditionView(model: model)
        case .completion(let entry):
            CompletionReviewSheet(model: model, entry: entry)
        case .book(let book):
            BookDetailView(model: model, book: book)
        case .review(let interval):
            ReadingSessionEditor(model: model, interval: interval)
        case .merge(let source):
            MergeBooksView(model: model, source: source)
        case .restore:
            RestoreConfirmationView(model: model)
        case .trackingHelp:
            TrackingHelpView(model: model)
        }
    }
}

struct ErrorBannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The clearing height the dashboard gave its garden, so self-checks can read what is really drawn.
struct GardenClearingKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// States that are hard to reach from a self-check, forced on through the environment.
struct ForcedScreenStates: Equatable {
    var importingAudio = false
    var historyUpdating = false
}

private struct ForcedScreenStatesKey: EnvironmentKey { static let defaultValue = ForcedScreenStates() }

extension EnvironmentValues {
    var forcedScreenStates: ForcedScreenStates {
        get { self[ForcedScreenStatesKey.self] }
        set { self[ForcedScreenStatesKey.self] = newValue }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case today, history, library, timeline, review, health, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .history: return "History"
        case .library: return "Library"
        case .review: return "Reviews"
        case .timeline: return "Timeline"
        case .health: return "Data health"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "text.book.closed"
        case .history: return "calendar"
        case .library: return "books.vertical"
        case .review: return "square.and.pencil"
        case .timeline: return "clock"
        case .health: return "heart.text.square"
        case .settings: return "gearshape"
        }
    }
}

enum DashboardSheet: Identifiable {
    case manualStart, manualAdd, completion(FinishedBookEntry), book(BookRecord), review(ReadingInterval), merge(BookRecord), restore, trackingHelp
    var id: String {
        switch self {
        case .manualStart: return "manualStart"
        case .manualAdd: return "manualAdd"
        case .completion(let entry): return "completion-\(entry.id)"
        case .book(let book): return "book-\(book.id)"
        case .review(let interval): return "review-\(interval.id)"
        case .merge(let book): return "merge-\(book.id)"
        case .restore: return "restore"
        case .trackingHelp: return "trackingHelp"
        }
    }
}

private struct DashboardSidebar: View {
    @Binding var selection: DashboardSection
    @ObservedObject var model: AppModel
    let troubleshoot: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedDestination: DashboardSection?
    @Namespace private var selectionHighlight
    private let destinations: [DashboardSection] = [.today, .library, .timeline, .history, .review, .settings]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 2) {
                    ForEach(destinations) { item in
                        Button { selection = item } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 14, weight: .regular))
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                            }
                                .foregroundStyle(ReadingPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 32)
                                .background {
                                    if selection == item {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(ReadingPalette.accent.opacity(0.14))
                                            .matchedGeometryEffect(id: "destination", in: selectionHighlight)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedDestination, equals: item)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(focusedDestination == item ? ReadingPalette.accent : .clear, lineWidth: 2))
                        .accessibilityAddTraits(selection == item ? .isSelected : [])
                        .accessibilityIdentifier("navigation-\(item.rawValue)")
                    }
                }
                .animation(reduceMotion ? nil : ReadingMotion.selection, value: selection)
                .onMoveCommand { direction in
                    guard direction == .up || direction == .down,
                          let index = destinations.firstIndex(of: focusedDestination ?? selection) else { return }
                    let next = min(destinations.count - 1, max(0, index + (direction == .down ? 1 : -1)))
                    focusedDestination = destinations[next]
                    selection = destinations[next]
                }
                Hairline().padding(.horizontal, 10)
                VStack(alignment: .leading, spacing: 5) {
                    if model.appleBooksTrackingNeedsAccess || model.snapshot.pauseReason == .captureFailure {
                        Button(action: troubleshoot) {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle").frame(width: 18)
                                Text(trackingStatus)
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.ink)
                        }.buttonStyle(.plain).help("Open tracking help")
                    } else {
                        HStack(spacing: 10) {
                            Circle().fill(model.snapshot.phase == .reading ? ReadingPalette.accent : ReadingPalette.secondaryInk)
                                .frame(width: 6, height: 6).frame(width: 18)
                            Text(trackingStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(ReadingPalette.ink)
                        }
                    }
                    Text("History stored on this Mac")
                        .font(.system(size: 10)).foregroundStyle(ReadingPalette.ink.opacity(0.8))
                        .padding(.leading, 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var trackingStatus: String {
        if !model.trackingEnabled { return "Tracking paused" }
        if model.snapshot.phase == .reading { return "Reading now" }
        switch model.snapshot.pauseReason {
        case .permissionLost: return "Apple Books access needed"
        case .background: return "Waiting for Books"
        case .locked, .displayAsleep: return "Tracking paused"
        case .captureFailure: return "Check tracking status"
        default: return "Waiting for a book"
        }
    }
}

@MainActor
struct ErrorBanner: View {
    let message: String
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).lineLimit(2)
            Spacer()
            Button("Try again", action: refresh)
        }
        .font(.callout)
        .foregroundStyle(ReadingPalette.ink)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(ReadingPalette.warning.opacity(0.26))
    }
}

/// Marks the floating sidebar panel in the AppKit view tree so the native
/// chrome smoke can measure its width and collapse state.
struct DashboardSidebarProbe: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("dashboard-sidebar")
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = Self.identifier
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
