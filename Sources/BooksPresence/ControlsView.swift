import SwiftUI
import BooksCore

@MainActor
struct ManualStartView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReadingSheetHeader(title: "Read manually", subtitle: "Track time with a paper book or another reader.", close: { dismiss() })
            VStack(spacing: 12) {
                TextField("Book title", text: $title)
                TextField("Author (optional)", text: $author)
            }.readingPanel()
            Text("Saved as manual reading time. Pages are not estimated.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            if let saveError { Text(saveError).font(.caption).foregroundStyle(ReadingPalette.warning) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start reading") {
                    if model.startManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        dismiss()
                    } else { saveError = model.errorMessage ?? "Could not start reading. Try again." }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 470)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss).textFieldStyle(ReadingTextFieldStyle())
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct ManualAdditionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loggingAudio = false
    @State private var title = ""
    @State private var author = ""
    @State private var end = Date()
    @State private var start = Date().addingTimeInterval(-30 * 60)
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReadingSheetHeader(title: "Add reading time", subtitle: nil, close: { dismiss() })
            Button("Log an audiobook instead…") { loggingAudio = true }
            VStack(alignment: .leading, spacing: 12) {
                Text("Book").font(.headline)
                TextField("Title", text: $title)
                TextField("Author (optional)", text: $author)
            }.readingPanel()
            VStack(alignment: .leading, spacing: 14) {
                Text("When you read").font(.headline)
                ReadingDatePicker("Started", selection: $start, maximumDate: Date())
                ReadingDatePicker("Finished", selection: $end, minimumDate: start, maximumDate: Date())
                Text("Saved as manual time. This does not add pages or Apple Books activity.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }.readingPanel()
            if end <= start || end > Date() {
                Text("Choose a finish time after the start and no later than now.")
                    .font(.caption).foregroundStyle(ReadingPalette.warning)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(ReadingPalette.warning) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add reading time") {
                    if model.addManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end) {
                        dismiss()
                    } else { saveError = model.errorMessage ?? "Could not save reading time. Try again." }
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start || end > Date())
            }
        }
        .sheet(isPresented: $loggingAudio) { AudiobookLogView(model: model) }
        .padding(26).frame(width: 500)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss).textFieldStyle(ReadingTextFieldStyle())
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct MergeBooksView: View {
    @ObservedObject var model: AppModel
    let source: BookRecord
    @Environment(\.dismiss) private var dismiss
    @State private var targetID = ""
    @State private var saveError: String?

    private var targets: [BookRecord] {
        let resolver = BookMergeResolver(merges: model.merges)
        return model.books.filter { $0.id != source.id && resolver.resolvedID(for: $0.id) == $0.id && $0.resolvedFormat != .audiobook }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadingSheetHeader(title: "Merge books", subtitle: nil, close: { dismiss() })
            Text("Merge \(source.title) into a selected record. Its recorded time will be shown with that record; you can reverse this decision later with Unmerge.")
                .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            if source.resolvedFormat == .audiobook {
                Text("Audiobook editions stay separate so their audio files and listening positions remain accessible.")
                    .foregroundStyle(ReadingPalette.secondaryInk)
            } else if targets.isEmpty {
                Text("There is no other text book available to merge with. Audiobook editions stay separate.").foregroundStyle(ReadingPalette.secondaryInk)
            } else {
                ReadingMenuPicker(label: "Merge into", options: [""] + targets.map(\.id), selection: $targetID) { id in
                    targets.first { $0.id == id }?.title ?? "Choose a book"
                }
                if let saveError { Text(saveError).font(.caption).foregroundStyle(ReadingPalette.warning) }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Merge") {
                        if let target = targets.first(where: { $0.id == targetID }) {
                            if model.mergeBooks(source: source, target: target) {
                                dismiss()
                            } else { saveError = model.errorMessage ?? "Could not merge these books. Try again." }
                        }
                    }
                    .buttonStyle(ReadingButtonStyle(emphasis: .primary)).disabled(!targets.contains { $0.id == targetID })
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(ReadingPalette.paper)
        .foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss)
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct HealthView: View {
    @ObservedObject var model: AppModel
    var showsHeading = true
    @State private var visibleOutages = 30
    private var outages: [AuditEvent] {
        model.events.filter {
            let value = $0.kind.lowercased()
            return value.contains("outage") || value.contains("gap") || value.contains("capture") || value.contains("permission") || value.contains("recovery") || value.contains("clock")
        }.sorted { $0.date > $1.date }
    }
    var body: some View {
        let events = outages
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showsHeading { PageHeader("Troubleshooting", subtitle: nil) }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 24, weight: .medium)).foregroundStyle(ReadingPalette.moss)
                            .frame(width: 52, height: 52)
                            .background(ReadingPalette.moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tracking status").font(ReadingType.bookTitle(22))
                            ActivityStateLabel(snapshot: model.snapshot)
                        }
                        Spacer()
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(ReadingButtonStyle(iconOnly: true)).accessibilityLabel("Refresh tracking status")
                    }
                    Text("Stillleaf’s reader records progress and active reading time without Accessibility access.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    DisclosureGroup("Optional Apple Books integration") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Accessibility is required only to track the book and page number shown in Apple Books.")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            LabeledValue(label: "Apple Books tracking access", value: model.accessibilityGranted ? "Allowed" : "Not allowed")
                            LabeledValue(label: "Last Apple Books capture", value: ReadingFormat.date(model.lastCapture))
                            HStack(spacing: 10) {
                                if !model.accessibilityGranted {
                                    Button("Allow Apple Books access") { model.requestAccessibility() }
                                }
                                Button("Accessibility settings") { model.openAccessibilitySettings() }
                            }
                        }.padding(.top, 10)
                    }
                    DisclosureGroup("More details") {
                        Text(model.health.isEmpty ? "No additional tracking details yet." : model.health)
                            .font(.caption).foregroundStyle(ReadingPalette.fadedInk).padding(.top, 6)
                    }
                }.readingPanel()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Tracking history").font(ReadingType.bookTitle(20))
                        Spacer()
                        Text("\(events.count) updates").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    }
                    if events.isEmpty {
                        ReadingEmptyState(title: "No issues recorded", symbol: "checkmark.shield", message: "Tracking gaps and recoveries will appear here if they occur.")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(events.prefix(visibleOutages)) { event in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(ReadingFormat.date(event.date)).font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.moss)
                                    Text(event.detail).font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Hairline()
                            }
                            if events.count > visibleOutages {
                                Button("Show more updates") { visibleOutages += 30 }
                            }
                        }
                    }
                    Text("A quiet reading day is not a tracking outage.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
            }
            .readingPage(maxWidth: 860)
        }
        .buttonStyle(ReadingButtonStyle())
    }
}

@MainActor
struct TrackingHelpView: View {
    @ObservedObject var model: AppModel
    @State private var showRecords = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            ReadingSheetHeader(title: "Troubleshooting", subtitle: nil, close: { dismiss() })
                .padding(.horizontal, 30).padding(.top, 24)
            HStack {
                Text("Reading time can be corrected without changing your personal book reviews.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                Spacer()
                Button("Reading records") { showRecords = true }.controlSize(.small)
            }.padding(.horizontal, 30).padding(.top, 18)
            HealthView(model: model, showsHeading: false)
        }
        .sheet(isPresented: $showRecords) { ReadingRecordsSheet(model: model).readingMotionAccessibility() }
        .frame(width: 740, height: 650)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle()).tint(ReadingPalette.moss)
    }
}

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
    @ObservedObject private var drafts: SettingsDraftStore
    @ObservedObject private var theme = ThemeStore.shared
    @State private var applyFeedback: String?
    @State private var applyFailed = false
    @State private var showAdvancedReading = false
    @State private var showAppleBooksSetup = false
    @State private var showDiscordConnection = false
    @State private var showRemoval = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 26) {
                        PageHeader("Settings", subtitle: nil)
                        ReadingMenuPicker(label: "Settings category", options: SettingsCategory.allCases,
                            selection: $category, title: { item in
                                item.title + ((item == .reading && readingDirty) || (item == .discord && discordDirty) ? " •" : "")
                            })
                    }
                    // Category controls keep focus across live theme changes.
                    // Theme changes re-key inside the entrance so the category never replays its fade.
                    categoryDetail
                        .id(Self.categoryKey(for: category, revision: theme.revision))
                        .readingEntrance().id(category)
                        .padding(.bottom, 4)
                }
                .readingPage(maxWidth: 820)
            }
            if currentCategoryDirty || applyFeedback != nil {
                Hairline()
                Group {
                    if currentCategoryDirty {
                applyBar(action: { if category == .reading { applyReadingDrafts() } else { applyDiscordDrafts() } },
                         label: category == .reading ? "Save reading changes" : "Save sharing changes",
                         valid: category != .reading || readingDraftsAreValid)
                    } else if let applyFeedback {
                        Label(applyFeedback, systemImage: applyFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption).foregroundStyle(applyFailed ? ReadingPalette.warning : ReadingPalette.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 820).padding(.horizontal, 40).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(ReadingPalette.canvas, ignoresSafeAreaEdges: .vertical)
                .id(theme.revision)
            }
        }
        // The dashboard owns drafts across destination and theme changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ReadingPalette.paper, ignoresSafeAreaEdges: .vertical).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss).buttonStyle(.bordered)
        .onAppear {
            loadDraftsIfNeeded()
            showDiscordConnection = model.discordNeedsSetup
        }
        .onChange(of: category) { _ in clearFeedback() }
        .onChange(of: model.discordNeedsSetup) { needed in if needed { showDiscordConnection = true } }
    }

    /// The Appearance picker observes the theme itself and keeps its identity, so the
    /// swatch someone just chose keeps keyboard and VoiceOver focus.
    static func categoryKey(for category: SettingsCategory, revision: Int) -> Int {
        category == .appearance ? -1 : revision
    }

    @ViewBuilder private var categoryDetail: some View {
        switch category {
        case .reading: readingSettings
        case .appearance: AppearancePicker(store: theme)
        case .discord: discordSettings
        case .data: dataSettings
        }
    }

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: 34) {
            ReadingSection("Daily goal") {
                VStack(alignment: .leading, spacing: 14) {
                    ReadingSegmentedControl(label: "Daily goal unit", options: [DailyGoalUnit.pages, .minutes],
                        selection: $drafts.dailyUnitDraft, title: { $0 == .pages ? "Pages" : "Minutes" })
                        .frame(maxWidth: 320)
                    HStack {
                        Text("Daily target").font(.callout)
                        Spacer(minLength: 8)
                        if drafts.dailyUnitDraft == .pages {
                            numericEditor(label: "Daily page goal", value: $drafts.pageGoalDraft, range: 1...10_000, stepperValue: pageGoalBinding)
                        } else {
                            numericEditor(label: "Daily goal minutes", value: $drafts.goalDraft, range: 1...1_440, stepperValue: goalBinding)
                        }
                    }
                    Text(drafts.dailyUnitDraft == .pages ? "Tracked and manually logged pages. Changes apply from today." : "Tracked and manually logged minutes. Changes apply from today.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ReadingSection("Books in \(String(model.goalYear))") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Set a yearly goal").font(.callout)
                        Spacer()
                        Toggle("Set a yearly books goal", isOn: $drafts.annualEnabledDraft).labelsHidden().toggleStyle(.switch)
                    }
                    if drafts.annualEnabledDraft {
                        HStack {
                            Text("\(model.annualBooksFinished) books finished so far").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                            Spacer()
                            numericEditor(label: "Yearly books goal", value: $drafts.annualGoalDraft, range: 1...10_000, stepperValue: annualGoalBinding)
                        }
                    }
                    Text("Counts books with a finish date this year.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
            ReadingSection("Tracking") {
                VStack(spacing: 0) {
                    SettingRow(icon: "book.closed", title: "Track reading", description: "Record active reading time and progress in Stillleaf and supported readers.") {
                        Toggle("Track reading", isOn: trackingBinding).labelsHidden().toggleStyle(.switch)
                    }
                    DisclosureGroup(isExpanded: $showAppleBooksSetup) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Stillleaf’s reader records page coverage, progress and active reading time without Accessibility access. Allow access here only if you want to track reading in Apple Books.")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            if !model.accessibilityGranted {
                                permissionNotice
                            } else {
                                Label("Apple Books tracking access allowed", systemImage: "checkmark.shield")
                                    .font(.caption).foregroundStyle(ReadingPalette.accent)
                            }
                            Button("Apple Books Accessibility settings") { model.openAccessibilitySettings() }
                                .controlSize(.small)
                        }.padding(.top, 12)
                    } label: {
                        Text("Optional Apple Books integration").font(.callout.weight(.medium))
                    }
                    .padding(.vertical, 14)
                    settingDivider
                    SettingRow(icon: "power", title: "Open at login", description: "") {
                        Toggle("Open at login", isOn: launchAtLoginBinding).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Hairline()
                DisclosureGroup(isExpanded: $showAdvancedReading) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Calendar time zone").font(.headline)
                            TimeZoneChooser(selection: $drafts.timezoneDraft)
                            Text("Determines when a new reading day begins.").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }.padding(.top, 14)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced reading").font(.headline)
                        Text("Calendar time zone")
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                }
            }
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 14) {
            Image(systemName: "accessibility").foregroundStyle(ReadingPalette.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Books access").font(.headline)
                Text("Accessibility access lets Stillleaf track the open book and page number in Apple Books.")
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer()
            Button("Allow Apple Books access") { model.requestAccessibility() }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary)).controlSize(.small)
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReadingPalette.warning.opacity(0.45), lineWidth: 1))
    }

    private var discordSettings: some View {
        VStack(alignment: .leading, spacing: 34) {
            ReadingSection("Discord") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(icon: "bubble.left.and.bubble.right", title: "Share reading on Discord", description: "Show your book while reading in Stillleaf or Apple Books.") {
                        Toggle("Share reading on Discord", isOn: discordBinding).labelsHidden().toggleStyle(.switch)
                    }
                    .help("Switching apps pauses the card for up to 20 minutes. Closing the reader clears it. Exclude individual books in Book details.")
                    HStack(spacing: 8) {
                        Image(systemName: model.discordNeedsSetup ? "exclamationmark.circle" : "dot.radiowaves.left.and.right")
                        Text(model.discordStatus).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.font(.caption).foregroundStyle(model.discordNeedsSetup ? ReadingPalette.warning : ReadingPalette.secondaryInk)
                        .padding(.leading, 32).padding(.bottom, 10)
                    settingDivider
                    SettingRow(icon: "photo", title: "Find cover art automatically", description: "Look up public cover links for Discord. Your local images are never uploaded.") {
                        Toggle("Find cover art automatically", isOn: automaticPublicCoversBinding).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Hairline()
                DisclosureGroup(isExpanded: $showDiscordConnection) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Discord Application ID").font(.headline)
                            TextField("Application ID", text: $drafts.discordApplicationIDDraft)
                                .textFieldStyle(ReadingTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                            Text("Use the Application ID from your Discord Developer Portal, not a token.")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            Link("Open Discord Developer Portal ↗", destination: URL(string: "https://discord.com/developers/applications")!)
                                .font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Fallback artwork (optional)").font(.headline)
                            TextField("Uploaded asset key", text: $drafts.discordAssetKeyDraft)
                                .textFieldStyle(ReadingTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                            Text("Used when a public cover isn't available. Leave blank if you haven't uploaded a Discord asset.")
                                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        if let result = model.lastDiscordResult {
                            Text("Last connection result: \(result)").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }.padding(.top, 14)
                } label: {
                    Label(model.discordNeedsSetup ? "Finish Discord setup" : "Discord connection", systemImage: "link")
                        .font(.headline)
                }
            }
        }
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 34) {
            ReadingSection("Apple Books") {
                VStack(alignment: .leading, spacing: 4) {
                    SettingRow(icon: "books.vertical", title: "Sync finished books", description: "Bring completion dates from Apple Books into your library. No pages or reading time are added.") {
                        Toggle("Sync finished books", isOn: appleHistorySyncBinding).labelsHidden().toggleStyle(.switch)
                    }
                    HStack(spacing: 12) {
                        Text(model.appleHistoryStatus).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Sync now") { model.syncAppleBooksHistory() }.controlSize(.small)
                            .disabled(!model.syncAppleBooksHistoryEnabled)
                    }.padding(.leading, 32)
                }
            }
            ReadingSection("Backups & export") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your reading history is stored on this Mac.")
                        .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                    HStack(spacing: 10) {
                        Button("Create backup") { model.backup() }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        Button("Restore backup…") { present(.restore) }
                    }
                    Hairline()
                    HStack {
                        Text("Reading archive").font(.callout)
                        Spacer()
                        Menu("Export…") {
                            Button("Full archive (JSON)") { model.exportJSON() }
                            Button("Spreadsheet tables (CSV)") { model.exportCSV() }
                        }.menuStyle(ReadingMenuStyle())
                        Button("Import archive…") { model.importJSON() }
                    }.controlSize(.small)
                    Text("Import adds records without duplicating them. Restore replaces your local history.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
            }
            ReadingSection("Help") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "questionmark.circle").font(.title3).foregroundStyle(ReadingPalette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Trouble with tracking?").font(.headline)
                            Text("Check permissions and recent tracking issues.").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                        Spacer()
                        Button("Troubleshooting") { present(.trackingHelp) }.controlSize(.small)
                    }
                    Hairline()
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles").font(.title3).foregroundStyle(ReadingPalette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Welcome tour").font(.headline)
                        }
                        Spacer()
                        Button("Show tour") { model.showOnboarding() }.controlSize(.small)
                    }
                }
            }
            DisclosureGroup("Reset or uninstall", isExpanded: $showRemoval) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Deleting removes history, managed backups, and cached covers. Copies you exported elsewhere remain.")
                        .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    HStack(spacing: 10) {
                        Button("Delete reading data…", role: .destructive, action: deleteAll)
                        Button("Uninstall Stillleaf…", role: .destructive, action: uninstall)
                    }.controlSize(.small)
                }.padding(.top, 14)
            }.font(.callout)
        }
    }

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

    private var goalBinding: Binding<Int> {
        Binding(get: { Int(drafts.goalDraft) ?? 20 }, set: { value in
            drafts.goalDraft = String(value)
            clearFeedback()
        })
    }

    private var pageGoalBinding: Binding<Int> {
        Binding(get: { Int(drafts.pageGoalDraft) ?? 20 }, set: { value in
            drafts.pageGoalDraft = String(value)
            clearFeedback()
        })
    }

    private var annualGoalBinding: Binding<Int> {
        Binding(get: { Int(drafts.annualGoalDraft) ?? 12 }, set: { drafts.annualGoalDraft = String($0); clearFeedback() })
    }
    private var readingDraftsAreValid: Bool {
        drafts.readingValuesAreValid
    }

    @ViewBuilder
    private func numericEditor(label: String, value: Binding<String>, range: ClosedRange<Int>, stepperValue: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: value)
                .textFieldStyle(ReadingTextFieldStyle())
                .frame(width: 78)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyReadingDrafts() }
            Text(label.contains("minute") ? "min" : label.contains("books") ? "books" : "pages").font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            Button { stepperValue.wrappedValue = max(range.lowerBound, stepperValue.wrappedValue - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(ReadingButtonStyle(iconOnly: true)).disabled(stepperValue.wrappedValue <= range.lowerBound)
                .accessibilityLabel("Decrease \(label)")
            Button { stepperValue.wrappedValue = min(range.upperBound, stepperValue.wrappedValue + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(ReadingButtonStyle(iconOnly: true)).disabled(stepperValue.wrappedValue >= range.upperBound)
                .accessibilityLabel("Increase \(label)")
        }
    }

    @ViewBuilder
    private func applyBar(action: @escaping () -> Void, label: String, valid: Bool) -> some View {
        HStack(spacing: 10) {
            Button(label, action: action)
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .disabled(!valid)
            if let applyFeedback {
                Label(applyFeedback, systemImage: applyFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(applyFailed ? ReadingPalette.ochre : ReadingPalette.moss)
            } else if !valid {
                Text("Use 1–10,000 pages or yearly books, 1–1,440 goal minutes, and a valid time zone.")
                    .font(.caption)
                    .foregroundStyle(ReadingPalette.secondaryInk)
            }
            Spacer()
            Button("Revert") {
                if category == .reading { reloadReadingDrafts() } else { reloadDiscordDrafts() }
                clearFeedback()
            }
                .buttonStyle(ReadingButtonStyle(emphasis: .secondary))
        }
        .padding(.horizontal, 2)
    }

    private var settingDivider: some View {
        Hairline().padding(.leading, 32)
    }

    private func setGoalPreset(_ minutes: Int) {
        drafts.goalDraft = String(minutes)
        clearFeedback()
    }

    private func setPageGoalPreset(_ pages: Int) {
        drafts.pageGoalDraft = String(pages)
        clearFeedback()
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
        if let pageGoal = Int(drafts.pageGoalDraft), (1...10_000).contains(pageGoal) {
            model.pageGoal = Double(pageGoal)
        }
        if let goal = Int(drafts.goalDraft), (1...1_440).contains(goal) {
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

private struct SettingsSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(ReadingType.bookTitle(19))
            Text(subtitle).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
        }
    }
}

private struct SettingRow<Control: View>: View {
    let icon: String
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ReadingPalette.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.vertical, 12)
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
        .background(ReadingPalette.paper)
        .foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
    }
}
