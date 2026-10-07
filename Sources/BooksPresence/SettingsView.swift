import SwiftUI
import BooksCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case reading = "Reading"
    case appearance = "Appearance"
    case discord = "Discord"
    case data = "Data"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .reading: return "Reading"
        case .appearance: return "Appearance"
        case .discord: return "Sharing"
        case .data: return "Data & privacy"
        }
    }

    var icon: String {
        switch self {
        case .reading: return "book.closed"
        case .appearance: return "paintpalette"
        case .discord: return "person.2.wave.2"
        case .data: return "externaldrive"
        }
    }

}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    let deleteAll: () -> Void
    let uninstall: () -> Void

    @State private var category: SettingsCategory
    /// Which way the last category change travelled, so the new page enters from that side.
    @State private var slide: CGFloat = 0
    @ObservedObject private var drafts: SettingsDraftStore
    @ObservedObject private var theme = ThemeStore.shared
    @State private var applyFeedback: String?
    @State private var applyFailed = false
    @State private var showDiscordConnection = false
    @State private var showRemoval = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativePreviewReduceMotion) private var previewReduceMotion

    init(
        model: AppModel,
        present: @escaping (DashboardSheet) -> Void,
        deleteAll: @escaping () -> Void,
        uninstall: @escaping () -> Void,
        initialCategory: SettingsCategory = .reading,
        drafts: SettingsDraftStore? = nil
    ) {
        self.model = model
        self.present = present
        self.deleteAll = deleteAll
        self.uninstall = uninstall
        _category = State(initialValue: initialCategory)
        _drafts = ObservedObject(wrappedValue: drafts ?? SettingsDraftStore())
    }

    private static let topAnchor = "settings-top"

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: ReadingMetrics.Space.xl) {
                    VStack(alignment: .leading, spacing: ReadingMetrics.Space.l) {
                        PageHeader("Settings", subtitle: nil)
                        categoryTabs
                    }
                    .id(Self.topAnchor)
                    // Category controls keep focus across live theme changes.
                    // Theme changes re-key inside the entrance so the category never replays its fade.
                    categoryDetail
                        .id(Self.categoryKey(for: category, revision: theme.revision))
                        .modifier(SettingsCategoryEntrance(direction: slide)).id(category)
                    // The save bar floats over the page, so room for it is always reserved
                    // and the page never changes height when changes appear.
                    Color.clear.frame(height: Self.barClearance)
                }
                .readingPage(maxWidth: ReadingMetrics.listWidth)
            }
            .onChange(of: category) { _ in
                clearFeedback()
                scroller.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
        // The dashboard owns drafts across destination and theme changes.
        .overlay(alignment: .bottom) { floatingBar }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent).buttonStyle(ReadingButtonStyle())
        .onAppear {
            loadDraftsIfNeeded()
            showDiscordConnection = model.discordNeedsSetup
        }
        .onChange(of: model.discordNeedsSetup) { needed in if needed { showDiscordConnection = true } }
        .task(id: applyFeedback) {
            // A confirmation fades on its own; a failure stays until it is dealt with.
            guard applyFeedback != nil, !applyFailed else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { clearFeedback() }
        }
    }

    /// The Appearance picker observes the theme itself and keeps its identity, so the
    /// swatch someone just chose keeps keyboard and VoiceOver focus.
    static func categoryKey(for category: SettingsCategory, revision: Int) -> Int {
        category == .appearance ? -1 : revision
    }

    /// Height kept clear under the content for the floating save bar.
    static let barClearance: CGFloat = 76

    // MARK: Navigation

    /// A glass tab strip rather than a second sidebar: the dashboard already has one,
    /// and four categories fit comfortably in a row.
    private var categoryTabs: some View {
        GlassSegmentedControl(
            label: "Settings category", options: SettingsCategory.allCases, selection: categoryBinding,
            title: { $0.title }, systemImage: { $0.icon }, style: .navigation, equalWidth: false,
            marker: { ($0 == .reading && readingDirty) || ($0 == .discord && discordDirty) }, onGlass: true)
            .fixedSize()
            .accessibilityIdentifier("settings-category")
    }

    private var categoryBinding: Binding<SettingsCategory> {
        Binding(get: { category }, set: { next in
            guard next != category else { return }
            let all = SettingsCategory.allCases
            slide = (all.firstIndex(of: next) ?? 0) > (all.firstIndex(of: category) ?? 0) ? 1 : -1
            category = next
        })
    }

    @ViewBuilder private var categoryDetail: some View {
        switch category {
        case .reading: readingSettings
        case .appearance: AppearancePicker(store: theme)
        case .discord: discordSettings
        case .data: dataSettings
        }
    }

    // MARK: Reading

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: ReadingMetrics.Space.xl) {
            ReadingSection("Daily goal") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Goal unit", description: "What your daily goal counts.") {
                        GlassSegmentedControl(label: "Daily goal unit", options: [DailyGoalUnit.pages, .minutes],
                            selection: edited($drafts.dailyUnitDraft), title: { $0 == .pages ? "Pages" : "Minutes" })
                            .frame(width: 210)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Daily target",
                                description: drafts.dailyUnitDraft == .pages ? "Tracked and manually logged pages. Changes apply from today." : "Tracked and manually logged minutes. Changes apply from today.") {
                        if drafts.dailyUnitDraft == .pages {
                            GlassNumberField(label: "Daily page goal", unit: "pages", text: edited($drafts.pageGoalDraft),
                                             range: ReadingGoalLimits.dailyPages, onCommit: { applyReadingDrafts() })
                        } else {
                            GlassNumberField(label: "Daily goal minutes", unit: "min", text: edited($drafts.goalDraft),
                                             range: ReadingGoalLimits.dailyMinutes, onCommit: { applyReadingDrafts() })
                        }
                    }
                }
            }
            ReadingSection("Books in \(String(model.goalYear))") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Yearly goal", description: "Counts books with a finish date this year.") {
                        GlassSwitch(label: "Set a yearly books goal", isOn: edited($drafts.annualEnabledDraft))
                    }
                    if drafts.annualEnabledDraft {
                        SettingsDivider()
                        SettingsRow(title: "Yearly target", description: "\(model.annualBooksFinished) books finished so far.") {
                            GlassNumberField(label: "Yearly books goal", unit: "books", text: edited($drafts.annualGoalDraft),
                                             range: ReadingGoalLimits.annualBooks, onCommit: { applyReadingDrafts() })
                        }
                        .transition(rowTransition)
                    }
                }
                .animation(rowAnimation, value: drafts.annualEnabledDraft)
            }
            ReadingSection("Your day") {
                SettingsRow(title: "Time zone", description: "Decides when a new reading day begins.") {
                    TimeZoneChooser(selection: edited($drafts.timezoneDraft)).controlSize(.small)
                }
            }
            ReadingSection("Tracking") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Track reading", description: "Record active reading time and progress in Stillleaf and supported readers.") {
                        GlassSwitch(label: "Track reading", isOn: trackingBinding)
                    }
                    SettingsDivider()
                    appleBooksAccess
                    SettingsDivider()
                    SettingsRow(title: "Open at login", description: "Start Stillleaf when you log in to your Mac.") {
                        GlassSwitch(label: "Open at login", isOn: launchAtLoginBinding)
                    }
                }
            }
        }
    }

    /// Stillleaf's own reader needs no permission; only tracking inside Apple Books does.
    private var appleBooksAccess: some View {
        SettingsRow(title: "Apple Books tracking",
                    description: model.accessibilityGranted
                        ? "Accessibility access is allowed, so Stillleaf can follow the open book and page in Apple Books."
                        : "Stillleaf’s reader needs no permission. Allow Accessibility access only if you also read in Apple Books.") {
            HStack(spacing: ReadingMetrics.Space.s) {
                if model.accessibilityGranted {
                    Label("Allowed", systemImage: "checkmark.shield")
                        .font(.callout.weight(.medium)).foregroundStyle(ReadingPalette.accent)
                } else {
                    Button("Allow access") { model.requestAccessibility() }
                        .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                }
                Button("Open settings") { model.openAccessibilitySettings() }
                    .accessibilityLabel("Open Apple Books Accessibility settings")
            }
            .controlSize(.small)
        }
    }

    // MARK: Sharing

    private var discordSettings: some View {
        VStack(alignment: .leading, spacing: ReadingMetrics.Space.xl) {
            ReadingSection("Discord") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(title: "Share reading on Discord", description: "Show your book while reading in Stillleaf or Apple Books.") {
                        GlassSwitch(label: "Share reading on Discord", isOn: discordBinding)
                    }
                    .help("Switching apps pauses the card for up to 20 minutes. Closing the reader clears it. Exclude individual books in Book details.")
                    SettingsStatus(text: model.discordStatus,
                                   systemImage: model.discordNeedsSetup ? "exclamationmark.circle" : "dot.radiowaves.left.and.right",
                                   warning: model.discordNeedsSetup) {
                        if model.discordNeedsSetup && !showDiscordConnection {
                            Button("Set up") { showDiscordConnection = true }.controlSize(.small)
                        }
                    }
                    SettingsDivider()
                    SettingsRow(title: "Find cover art automatically", description: "Look up public cover links for Discord. Your local images are never uploaded.") {
                        GlassSwitch(label: "Find cover art automatically", isOn: automaticPublicCoversBinding)
                    }
                }
            }
            ReadingSection("Connection") {
                GlassDisclosure(title: model.discordNeedsSetup ? "Finish Discord setup" : "Application ID and artwork",
                                subtitle: model.discordNeedsSetup ? "Add your Discord Application ID to start sharing." : nil,
                                systemImage: "link",
                                isExpanded: $showDiscordConnection) {
                    VStack(alignment: .leading, spacing: ReadingMetrics.Space.l) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Discord Application ID").font(.headline)
                            TextField("Application ID", text: edited($drafts.discordApplicationIDDraft))
                                .textFieldStyle(GlassTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                            Text("Use the Application ID from your Discord Developer Portal, not a token.")
                                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                            Link("Open Discord Developer Portal ↗", destination: URL(string: "https://discord.com/developers/applications")!)
                                .font(.callout).buttonStyle(.plain).foregroundStyle(ReadingPalette.accent)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Fallback artwork (optional)").font(.headline)
                            TextField("Uploaded asset key", text: edited($drafts.discordAssetKeyDraft))
                                .textFieldStyle(GlassTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                            Text("Used when a public cover isn't available. Leave blank if you haven't uploaded a Discord asset.")
                                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let result = model.lastDiscordResult {
                            Text("Last connection result: \(result)").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }
                }
            }
        }
    }

    // MARK: Data & privacy

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: ReadingMetrics.Space.xl) {
            ReadingSection("Apple Books") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Sync finished books", description: "Bring completion dates from Apple Books into your library. No pages or reading time are added.") {
                        GlassSwitch(label: "Sync finished books", isOn: appleHistorySyncBinding)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Sync status", description: model.appleHistoryStatus) {
                        Button("Sync now") { model.syncAppleBooksHistory() }.controlSize(.small)
                            .disabled(!model.syncAppleBooksHistoryEnabled)
                    }
                }
            }
            ReadingSection("Backups & export") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Backup", description: "Your reading history is stored on this Mac.") {
                        HStack(spacing: ReadingMetrics.Space.s) {
                            Button("Create backup") { model.backup() }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                            Button("Restore backup…") { present(.restore) }
                        }.controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Reading archive", description: "Import adds records without duplicating them. Restore replaces your local history.") {
                        HStack(spacing: ReadingMetrics.Space.s) {
                            Menu("Export…") {
                                Button("Full archive (JSON)") { model.exportJSON() }
                                Button("Spreadsheet tables (CSV)") { model.exportCSV() }
                            }.menuStyle(ReadingMenuStyle())
                            Button("Import archive…") { model.importJSON() }
                        }.controlSize(.small)
                    }
                }
            }
            ReadingSection("Help") {
                VStack(spacing: 0) {
                    SettingsRow(title: "Trouble with tracking?", description: "Check permissions and recent tracking issues.") {
                        Button("Troubleshooting") { present(.trackingHelp) }.controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Welcome tour", description: "Replay the introduction to Stillleaf.") {
                        Button("Show tour") { model.showOnboarding() }.controlSize(.small)
                    }
                }
            }
            ReadingSection("Reset") {
                GlassDisclosure(title: "Reset or uninstall", subtitle: "Delete reading data or remove Stillleaf from this Mac.",
                                isExpanded: $showRemoval) {
                    VStack(alignment: .leading, spacing: ReadingMetrics.Space.m) {
                        Text("Deleting removes history, managed backups, and cached covers. Copies you exported elsewhere remain.")
                            .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: ReadingMetrics.Space.s) {
                            Button("Delete reading data…", role: .destructive, action: deleteAll)
                            Button("Uninstall Stillleaf…", role: .destructive, action: uninstall)
                        }.controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Save bar

    private enum BarState: Int { case hidden, unsaved, confirmation }
    private var barState: BarState {
        if currentCategoryDirty { return .unsaved }
        return applyFeedback != nil ? .confirmation : .hidden
    }

    /// Reading and Sharing keep an explicit Save and Revert; the bar floats at the bottom
    /// and slides in, so appearing never moves the page. A toast confirms instant switches.
    private var floatingBar: some View {
        ZStack(alignment: .bottom) {
            switch barState {
            case .hidden: EmptyView()
            case .unsaved: saveBar.transition(barTransition)
            case .confirmation: toast.transition(barTransition)
            }
        }
        .frame(maxWidth: ReadingMetrics.listWidth)
        .padding(.horizontal, ReadingMetrics.pageInset).padding(.bottom, ReadingMetrics.Space.l)
        .frame(maxWidth: .infinity)
        .animation(motionOff ? nil : ReadingMotion.selection, value: barState)
    }

    private var saveBar: some View {
        let valid = category != .reading || readingDraftsAreValid
        return HStack(spacing: ReadingMetrics.Space.m) {
            if let applyFeedback, applyFailed {
                Label(applyFeedback, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(ReadingPalette.warning)
            } else if !valid {
                Text("Use 1–10,000 pages or yearly books, 1–1,440 goal minutes, and a valid time zone.")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            } else {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .labelStyle(UnsavedLabelStyle())
                    .font(.callout.weight(.medium))
            }
            Spacer(minLength: ReadingMetrics.Space.m)
            Button("Revert") {
                if category == .reading { reloadReadingDrafts() } else { reloadDiscordDrafts() }
                clearFeedback()
            }
            Button(category == .reading ? "Save reading changes" : "Save sharing changes") {
                if category == .reading { applyReadingDrafts() } else { applyDiscordDrafts() }
            }
            .buttonStyle(ReadingButtonStyle(emphasis: .primary))
            .disabled(!valid)
        }
        .padding(.horizontal, ReadingMetrics.Space.l).padding(.vertical, ReadingMetrics.Space.m)
        // Cards scroll under the bar. Glass alone lets their text show through, so it sits on a near-opaque backing.
        .background(ReadingPalette.canvas.opacity(0.94), in: RoundedRectangle(cornerRadius: ReadingMetrics.Radius.card, style: .continuous))
        .glassSurface(cornerRadius: ReadingMetrics.Radius.card)
        .id(theme.revision)
    }

    private var toast: some View {
        Label(applyFeedback ?? "", systemImage: applyFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(applyFailed ? ReadingPalette.warning : ReadingPalette.accent)
            .padding(.horizontal, ReadingMetrics.Space.l).padding(.vertical, ReadingMetrics.Space.s + 2)
            .background(ReadingPalette.canvas.opacity(0.94), in: Capsule())
            .glassSurface(cornerRadius: 20)
            .id(theme.revision)
            .accessibilityElement(children: .combine)
    }

    private var motionOff: Bool { previewReduceMotion ?? reduceMotion }
    private var barTransition: AnyTransition {
        motionOff ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }
    private var rowTransition: AnyTransition {
        motionOff ? .identity : .opacity.combined(with: .move(edge: .top))
    }
    private var rowAnimation: Animation? { motionOff ? nil : ReadingMotion.selection }

    // MARK: Drafts

    private var readingDirty: Bool {
        drafts.didLoadDrafts && (drafts.dailyUnitDraft != model.dailyGoalUnit
            || drafts.annualEnabledDraft != (model.annualBookGoal != nil)
            || (drafts.annualEnabledDraft && drafts.annualGoalDraft != String(model.annualBookGoal ?? 12))
            || drafts.pageGoalDraft != String(Int(model.pageGoal.rounded()))
            || drafts.goalDraft != String(Int(model.goalMinutes.rounded()))
            || drafts.timezoneDraft != model.timezoneID)
    }
    private var discordDirty: Bool {
        drafts.didLoadDrafts && (drafts.discordApplicationIDDraft != model.discordApplicationID || drafts.discordAssetKeyDraft != model.discordAssetKey)
    }
    private var currentCategoryDirty: Bool { category == .reading ? readingDirty : category == .discord ? discordDirty : false }

    /// Editing a draft retires a stale confirmation such as "Reading settings applied."
    private func edited<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; clearFeedback() })
    }

    private var trackingBinding: Binding<Bool> {
        Binding(get: { model.trackingEnabled }, set: { enabled in
            model.trackingEnabled = enabled
            showFeedback(enabled ? "Tracking enabled." : "Tracking paused.")
        })
    }

    private var discordBinding: Binding<Bool> {
        Binding(get: { model.discordEnabled }, set: { enabled in
            model.discordEnabled = enabled
            showFeedback(enabled ? "Discord sharing enabled." : "Discord sharing turned off.")
        })
    }

    private var automaticPublicCoversBinding: Binding<Bool> {
        Binding(get: { model.automaticPublicCovers }, set: { enabled in
            model.automaticPublicCovers = enabled
            model.saveSettings()
            showResult(success: enabled ? "Automatic public cover lookup enabled." : "Automatic public cover lookup disabled.")
        })
    }

    private var appleHistorySyncBinding: Binding<Bool> {
        Binding(get: { model.syncAppleBooksHistoryEnabled }, set: { enabled in
            model.syncAppleBooksHistoryEnabled = enabled
            model.saveSettings()
            if enabled { model.syncAppleBooksHistory() }
            showResult(success: enabled ? "Apple Books history sync enabled." : "Apple Books history sync paused.")
        })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { enabled in
            model.setLaunchAtLogin(enabled)
            showResult(success: enabled ? "Launch at login enabled." : "Launch at login disabled.")
        })
    }

    private var readingDraftsAreValid: Bool {
        drafts.readingValuesAreValid
    }

    private func loadDraftsIfNeeded() {
        drafts.loadIfNeeded(from: model)
    }

    private func reloadReadingDrafts() {
        drafts.reloadReading(from: model)
    }

    private func reloadDiscordDrafts() {
        drafts.reloadSharing(from: model)
        clearFeedback()
    }

    private func applyReadingDrafts() {
        guard readingDraftsAreValid else {
            applyFeedback = "Choose a page goal from 1–10,000 pages, a time goal from 1–1,440 minutes, and a valid time zone."
            applyFailed = true
            return
        }
        let previous = (model.pageGoal, model.goalMinutes, model.dailyGoalUnit, model.annualBookGoal, model.timezoneID)
        model.dailyGoalUnit = drafts.dailyUnitDraft
        model.annualBookGoal = drafts.annualEnabledDraft ? Int(drafts.annualGoalDraft) : nil
        // An invalid hidden unit must neither block the active goal nor replace
        // the last saved value. Valid drafts for either unit can still be saved.
        if let pageGoal = Int(drafts.pageGoalDraft), ReadingGoalLimits.dailyPages.contains(pageGoal) {
            model.pageGoal = Double(pageGoal)
        }
        if let goal = Int(drafts.goalDraft), ReadingGoalLimits.dailyMinutes.contains(goal) {
            model.goalMinutes = Double(goal)
        }
        model.timezoneID = drafts.timezoneDraft
        model.saveSettings()
        if model.errorMessage != nil {
            model.pageGoal = previous.0; model.goalMinutes = previous.1; model.dailyGoalUnit = previous.2
            model.annualBookGoal = previous.3; model.timezoneID = previous.4
        } else { reloadReadingDrafts() }
        showResult(success: "Reading settings applied.")
    }

    private func applyDiscordDrafts() {
        drafts.saveSharing(to: model)
        showResult(success: "Sharing settings saved.")
    }

    private func showResult(success: String) {
        if let error = model.errorMessage {
            applyFeedback = error
            applyFailed = true
        } else {
            showFeedback(success)
        }
    }

    private func showFeedback(_ message: String) {
        applyFeedback = message
        applyFailed = false
    }

    private func clearFeedback() {
        applyFeedback = nil
        applyFailed = false
    }
}

/// A filled accent dot before the text, sized to the line.
private struct UnsavedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ReadingPalette.accent).frame(width: 7, height: 7).accessibilityHidden(true)
            configuration.title
        }
    }
}

@MainActor
struct RestoreConfirmationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadingSheetHeader(title: "Restore a backup?", subtitle: "Replace the history saved on this Mac.", close: { dismiss() })
            Text("Restore validates the selected backup and replaces the current local database. Create a new backup first if you want to preserve current data.")
                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Choose backup and restore", role: .destructive) {
                    model.restore()
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(ReadingPalette.canvas)
        .foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
    }
}
