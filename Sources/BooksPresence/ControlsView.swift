import SwiftUI
import BooksCore

@MainActor
struct ManualStartView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReadingSheetHeader(title: "Read manually", subtitle: "Track time with a paper book or another reader.", close: { dismiss() })
            VStack(spacing: 12) {
                TextField("Book title", text: $title)
                TextField("Author (optional)", text: $author)
            }.readingPanel()
            Text("Saved as manual reading time. Pages are not estimated.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start reading") {
                    model.startManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
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
    @State private var title = ""
    @State private var author = ""
    @State private var end = Date()
    @State private var start = Date().addingTimeInterval(-30 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ReadingSheetHeader(title: "Add reading time", subtitle: "Keep a reading session in your journal.", close: { dismiss() })
            VStack(alignment: .leading, spacing: 12) {
                Text("Book").font(.headline)
                TextField("Title", text: $title)
                TextField("Author (optional)", text: $author)
            }.readingPanel()
            VStack(alignment: .leading, spacing: 14) {
                Text("When you read").font(.headline)
                DatePicker("Started", selection: $start).datePickerStyle(.compact)
                DatePicker("Finished", selection: $end, in: start...).datePickerStyle(.compact)
                Text("Saved as manual time. This does not add pages or Apple Books activity.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }.readingPanel()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add reading time") {
                    model.addManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end)
                    dismiss()
                }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
            }
        }
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

    private var targets: [BookRecord] {
        let resolver = BookMergeResolver(merges: model.merges)
        return model.books.filter { $0.id != source.id && resolver.resolvedID(for: $0.id) == $0.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadingSheetHeader(title: "Merge books", subtitle: "Bring duplicate records together.", close: { dismiss() })
            Text("Merge \(source.title) into a selected record. Its recorded time will be shown with that record; you can reverse this decision later with Unmerge.")
                .font(.callout).foregroundStyle(.secondary)
            if targets.isEmpty {
                Text("There is no other book record available to merge with.").foregroundStyle(.secondary)
            } else {
                ReadingMenuPicker(label: "Merge into", options: [""] + targets.map(\.id), selection: $targetID) { id in
                    targets.first { $0.id == id }?.title ?? "Choose a book"
                }
                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Merge") {
                        if let target = targets.first(where: { $0.id == targetID }) {
                            model.mergeBooks(source: source, target: target)
                            dismiss()
                        }
                    }
                    .buttonStyle(ReadingButtonStyle(emphasis: .primary)).disabled(targetID.isEmpty)
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
                if showsHeading { PageHeading(title: "Troubleshooting", subtitle: "Check permissions and recent tracking issues.") }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: model.accessibilityGranted ? "checkmark.shield" : "lock.shield")
                            .font(.system(size: 24, weight: .medium)).foregroundStyle(ReadingPalette.moss)
                            .frame(width: 52, height: 52)
                            .background(ReadingPalette.moss.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tracking status").font(.system(size: 20, weight: .semibold, design: .rounded))
                            ActivityStateLabel(snapshot: model.snapshot)
                        }
                        Spacer()
                        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(ReadingButtonStyle(iconOnly: true)).accessibilityLabel("Refresh tracking status")
                    }
                    HStack(spacing: 30) {
                        LabeledValue(label: "Accessibility", value: model.accessibilityGranted ? "Allowed" : "Needs access")
                        LabeledValue(label: "Last reading captured", value: ReadingFormat.date(model.lastCapture))
                    }
                    HStack(spacing: 10) {
                        if !model.accessibilityGranted {
                            Button("Enable tracking access") { model.requestAccessibility() }
                                .buttonStyle(ReadingButtonStyle(emphasis: .primary))
                        }
                        Button("Accessibility settings") { model.openAccessibilitySettings() }
                    }
                    DisclosureGroup("More details") {
                        Text(model.health.isEmpty ? "No additional tracking details yet." : model.health)
                            .font(.caption).foregroundStyle(ReadingPalette.fadedInk).padding(.top, 6)
                    }
                }.readingPanel()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Tracking history").font(.system(size: 19, weight: .semibold, design: .rounded))
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
                                Divider().opacity(0.45)
                            }
                            if events.count > visibleOutages {
                                Button("Show more updates") { visibleOutages += 30 }
                            }
                        }
                    }
                    Text("A quiet reading day is not a tracking outage.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }.readingPanel()
            }
            .frame(maxWidth: 1060, alignment: .leading).padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
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
            ReadingSheetHeader(title: "Troubleshooting", subtitle: "Check permissions and recent tracking issues.", close: { dismiss() })
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
    case discord = "Discord"
    case data = "Data"

    var id: String { rawValue }
    var title: String { self == .discord ? "Sharing" : self == .data ? "Data & privacy" : "Reading" }

    var icon: String {
        switch self {
        case .reading: return "book.closed"
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
    @ObservedObject private var theme = ThemeStore.shared
    @State private var didLoadDrafts = false
    @State private var pageGoalDraft = "20"
    @State private var goalDraft = "20"
    @State private var dailyUnitDraft: DailyGoalUnit = .pages
    @State private var annualEnabledDraft = false
    @State private var annualGoalDraft = "12"
    @State private var uncertaintyDraft = "20"
    @State private var timezoneDraft = TimeZone.current.identifier
    @State private var discordApplicationIDDraft = ""
    @State private var discordAssetKeyDraft = "books"
    @State private var applyFeedback: String?
    @State private var applyFailed = false
    @State private var showAdvancedReading = false
    @State private var showDiscordConnection = false
    @State private var showRemoval = false

    init(
        model: AppModel,
        present: @escaping (DashboardSheet) -> Void,
        deleteAll: @escaping () -> Void,
        uninstall: @escaping () -> Void,
        initialCategory: SettingsCategory = .reading
    ) {
        self.model = model
        self.present = present
        self.deleteAll = deleteAll
        self.uninstall = uninstall
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Settings", subtitle: "Make Stillleaf fit your reading.")
            ReadingSegmentedControl(label: "Settings category", options: SettingsCategory.allCases,
                selection: $category, title: { item in
                    item.title + ((item == .reading && readingDirty) || (item == .discord && discordDirty) ? " •" : "")
                })
            ScrollView {
                categoryDetail
                    .readingEntrance().id(category)
                    .padding(.bottom, 4)
            }
            if currentCategoryDirty {
                applyBar(action: { if category == .reading { applyReadingDrafts() } else { applyDiscordDrafts() } },
                         label: category == .reading ? "Save reading changes" : "Save sharing changes",
                         valid: category != .reading || readingDraftsAreValid)
            } else if let applyFeedback {
                Label(applyFeedback, systemImage: applyFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption).foregroundStyle(applyFailed ? ReadingPalette.ochre : ReadingPalette.fadedInk)
            }
        }
        // Re-key the rendered content only; drafts live in this view's own state and survive.
        .id(theme.revision)
        .frame(maxWidth: 840, maxHeight: .infinity, alignment: .topLeading)
        .padding(30).frame(maxWidth: .infinity, alignment: .top)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.moss).buttonStyle(ReadingButtonStyle())
        .onAppear {
            loadDraftsIfNeeded()
            showDiscordConnection = model.discordNeedsSetup
        }
        .onChange(of: category) { _ in clearFeedback() }
        .onChange(of: model.discordNeedsSetup) { needed in if needed { showDiscordConnection = true } }
    }

    @ViewBuilder private var categoryDetail: some View {
        switch category {
        case .reading: readingSettings
        case .discord: discordSettings
        case .data: dataSettings
        }
    }

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.automaticTrackingNeedsAccess { permissionNotice }
            VStack(alignment: .leading, spacing: 16) {
                Text("Your daily goal").font(.system(size: 19, weight: .semibold, design: .rounded))
                ReadingSegmentedControl(label: "Daily goal unit", options: [DailyGoalUnit.pages, .minutes],
                    selection: $dailyUnitDraft, title: { $0 == .pages ? "Pages" : "Minutes" })
                HStack {
                    Text("A little reading, every day.").font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                    Spacer(minLength: 8)
                    if dailyUnitDraft == .pages {
                        numericEditor(label: "Daily page goal", value: $pageGoalDraft, range: 1...10_000, stepperValue: pageGoalBinding)
                    } else {
                        numericEditor(label: "Daily goal minutes", value: $goalDraft, range: 1...1_440, stepperValue: goalBinding)
                    }
                }
                Text(dailyUnitDraft == .pages ? "Counts tracked pages and pages you add yourself." : "Counts credited reading time, including manual sessions. Unconfirmed time waits for review.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                Text("Each unit remembers its own target. Changes apply from today.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }.readingPanel()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your \(String(model.goalYear)) books goal").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("An optional goal for books finished this year.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    }
                    Spacer()
                    Toggle("Set a yearly books goal", isOn: $annualEnabledDraft).labelsHidden().toggleStyle(.switch)
                }
                if annualEnabledDraft {
                    HStack {
                        Text("\(model.annualBooksFinished) books finished so far").font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                        Spacer()
                        numericEditor(label: "Yearly books goal", value: $annualGoalDraft, range: 1...10_000, stepperValue: annualGoalBinding)
                    }
                }
                Text("Uses confirmed finish dates in your calendar time zone. Undated books are excluded.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }.readingPanel()
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "book.closed", title: "Track Apple Books", description: "Record reading automatically on this Mac.") {
                        Toggle("Track Apple Books", isOn: trackingBinding).labelsHidden().toggleStyle(.switch)
                    }
                    settingDivider
                    SettingRow(icon: "power", title: "Open at login", description: "Keep Stillleaf ready in your menu bar.") {
                        Toggle("Open at login", isOn: launchAtLoginBinding).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            DisclosureGroup(isExpanded: $showAdvancedReading) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Calendar time zone").font(.headline)
                        TimeZoneChooser(selection: $timezoneDraft)
                        Text("Determines when a new reading day begins.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    }
                    Divider().opacity(0.4)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Review unconfirmed time after").font(.headline)
                            Text("Reading without fresh evidence is kept for review.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        }
                        Spacer()
                        numericEditor(label: "Review threshold minutes", value: $uncertaintyDraft, range: 1...240, stepperValue: uncertaintyBinding)
                    }
                }.padding(.top, 16)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced reading").font(.headline)
                    Text("Review behavior · \(timezoneDraft.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
            }.padding(18).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            Text("Tracking and login switches save immediately. Goals and advanced changes use Save below.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 14) {
            Image(systemName: "accessibility").foregroundStyle(ReadingPalette.ochre)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow automatic tracking").font(.headline)
                Text("Stillleaf needs Accessibility access to read your book's page number.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }
            Spacer()
            Button("Allow access") { model.requestAccessibility() }
                .buttonStyle(ReadingButtonStyle(emphasis: .primary)).controlSize(.small)
        }.padding(16).background(ReadingPalette.ochre.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var discordSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "bubble.left.and.bubble.right", title: "Share reading on Discord", description: "Show your book while its Apple Books reader is open.") {
                        Toggle("Share reading on Discord", isOn: discordBinding).labelsHidden().toggleStyle(.switch)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: model.discordNeedsSetup ? "exclamationmark.circle" : "dot.radiowaves.left.and.right")
                        Text(model.discordStatus).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.font(.caption).foregroundStyle(model.discordNeedsSetup ? ReadingPalette.ochre : ReadingPalette.fadedInk)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            settingsCard {
                SettingRow(icon: "photo", title: "Find cover art automatically", description: "Look up public cover links for Discord. Your local images are never uploaded.") {
                    Toggle("Find cover art automatically", isOn: automaticPublicCoversBinding).labelsHidden().toggleStyle(.switch)
                }
            }
            DisclosureGroup(isExpanded: $showDiscordConnection) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Discord Application ID").font(.headline)
                        TextField("Application ID", text: $discordApplicationIDDraft)
                            .textFieldStyle(ReadingTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                        Text("Use the Application ID from your Discord Developer Portal, not a token.")
                            .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                        Link("Open Discord Developer Portal ↗", destination: URL(string: "https://discord.com/developers/applications")!)
                            .font(.caption)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Fallback artwork (optional)").font(.headline)
                        TextField("Uploaded asset key", text: $discordAssetKeyDraft)
                            .textFieldStyle(ReadingTextFieldStyle()).onSubmit { applyDiscordDrafts() }
                        Text("Used when a public cover isn't available. Leave blank if you haven't uploaded a Discord asset.")
                            .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    }
                    if let result = model.lastDiscordResult {
                        Text("Last connection result: \(result)").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    }
                }.padding(.top, 16)
            } label: {
                Label(model.discordNeedsSetup ? "Finish Discord setup" : "Discord connection", systemImage: "link")
                    .font(.headline)
            }.padding(18).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            Text("Switching apps keeps a paused card for up to 20 minutes. Closing the reader clears it. Exclude individual books in Book details.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
        }
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "books.vertical", title: "Sync finished books", description: "Bring completion dates from Apple Books into your library. No pages or reading time are added.") {
                        Toggle("Sync finished books", isOn: appleHistorySyncBinding).labelsHidden().toggleStyle(.switch)
                    }
                    HStack(spacing: 12) {
                        Text(model.appleHistoryStatus).font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Sync now") { model.syncAppleBooksHistory() }.controlSize(.small)
                            .disabled(!model.syncAppleBooksHistoryEnabled)
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Your history, kept here").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("Reading history stays on this Mac. Keep a backup wherever you choose.")
                    .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                HStack(spacing: 10) {
                    Button("Create backup") { model.backup() }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    Button("Restore backup…") { present(.restore) }
                }
                Divider().opacity(0.4)
                HStack {
                    Text("Move or explore your history").font(.callout)
                    Spacer()
                    Menu("Export…") {
                        Button("Full archive (JSON)") { model.exportJSON() }
                        Button("Spreadsheet tables (CSV)") { model.exportCSV() }
                    }.menuStyle(.borderlessButton).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(ReadingPalette.moss.opacity(0.075), in: RoundedRectangle(cornerRadius: 9))
                    Button("Import archive…") { model.importJSON() }
                }.controlSize(.small)
                Text("Import adds records without duplicating them. Restore replaces your local history.")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            }.readingPanel()
            HStack(spacing: 14) {
                Image(systemName: "questionmark.circle").font(.title3).foregroundStyle(ReadingPalette.moss)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trouble with tracking?").font(.headline)
                    Text("Check permissions and recent tracking issues.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Button("Troubleshooting") { present(.trackingHelp) }.controlSize(.small)
            }.padding(18).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            DisclosureGroup("Reset or uninstall", isExpanded: $showRemoval) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Deleting removes history, managed backups, and cached covers. Copies you exported elsewhere remain.")
                        .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                    HStack(spacing: 10) {
                        Button("Delete reading data…", role: .destructive, action: deleteAll)
                        Button("Uninstall Stillleaf…", role: .destructive, action: uninstall)
                    }.controlSize(.small)
                }.padding(.top, 14)
            }.font(.callout).padding(.horizontal, 4)
        }
    }

    private var readingDirty: Bool {
        didLoadDrafts && (dailyUnitDraft != model.dailyGoalUnit
            || annualEnabledDraft != (model.annualBookGoal != nil)
            || (annualEnabledDraft && annualGoalDraft != String(model.annualBookGoal ?? 12))
            || pageGoalDraft != String(Int(model.pageGoal.rounded()))
            || goalDraft != String(Int(model.goalMinutes.rounded()))
            || uncertaintyDraft != String(Int(model.uncertaintyMinutes.rounded())) || timezoneDraft != model.timezoneID)
    }
    private var discordDirty: Bool {
        didLoadDrafts && (discordApplicationIDDraft != model.discordApplicationID || discordAssetKeyDraft != model.discordAssetKey)
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
        Binding(get: { Int(goalDraft) ?? 20 }, set: { value in
            goalDraft = String(value)
            clearFeedback()
        })
    }

    private var pageGoalBinding: Binding<Int> {
        Binding(get: { Int(pageGoalDraft) ?? 20 }, set: { value in
            pageGoalDraft = String(value)
            clearFeedback()
        })
    }

    private var annualGoalBinding: Binding<Int> {
        Binding(get: { Int(annualGoalDraft) ?? 12 }, set: { annualGoalDraft = String($0); clearFeedback() })
    }
    private var uncertaintyBinding: Binding<Int> {
        Binding(get: { Int(uncertaintyDraft) ?? 20 }, set: { value in
            uncertaintyDraft = String(value)
            clearFeedback()
        })
    }

    private var readingDraftsAreValid: Bool {
        guard let pageGoal = Int(pageGoalDraft), (1...10_000).contains(pageGoal),
              let goal = Int(goalDraft), (1...1_440).contains(goal),
              let uncertainty = Int(uncertaintyDraft), (1...240).contains(uncertainty),
              TimeZone(identifier: timezoneDraft) != nil else { return false }
        return !annualEnabledDraft || Int(annualGoalDraft).map { (1...10_000).contains($0) } == true
    }

    @ViewBuilder
    private func numericEditor(label: String, value: Binding<String>, range: ClosedRange<Int>, stepperValue: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: value)
                .textFieldStyle(ReadingTextFieldStyle())
                .frame(width: 78)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyReadingDrafts() }
            Text(label.contains("minute") ? "min" : label.contains("books") ? "books" : "pages").font(.callout).foregroundStyle(.secondary)
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
                Text("Use 1–10,000 pages or yearly books, 1–1,440 goal minutes, and 1–240 review minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        Divider().padding(.leading, 44)
    }

    private func setGoalPreset(_ minutes: Int) {
        goalDraft = String(minutes)
        clearFeedback()
    }

    private func setPageGoalPreset(_ pages: Int) {
        pageGoalDraft = String(pages)
        clearFeedback()
    }

    private func loadDraftsIfNeeded() {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true
        reloadDrafts()
    }

    private func reloadDrafts() { reloadReadingDrafts(); reloadDiscordDrafts(); clearFeedback() }

    private func reloadReadingDrafts() {
        dailyUnitDraft = model.dailyGoalUnit
        annualEnabledDraft = model.annualBookGoal != nil
        annualGoalDraft = String(model.annualBookGoal ?? 12)
        pageGoalDraft = String(Int(model.pageGoal.rounded()))
        goalDraft = String(Int(model.goalMinutes.rounded()))
        uncertaintyDraft = String(Int(model.uncertaintyMinutes.rounded()))
        timezoneDraft = model.timezoneID
    }

    private func reloadDiscordDrafts() {
        discordApplicationIDDraft = model.discordApplicationID
        discordAssetKeyDraft = model.discordAssetKey
        clearFeedback()
    }

    private func applyReadingDrafts() {
        guard readingDraftsAreValid, let pageGoal = Int(pageGoalDraft), let goal = Int(goalDraft), let uncertainty = Int(uncertaintyDraft) else {
            applyFeedback = "Choose a page goal from 1–10,000 pages, a time goal from 1–1,440 minutes, a review threshold from 1–240 minutes, and a valid time zone."
            applyFailed = true
            return
        }
        let previous = (model.pageGoal, model.goalMinutes, model.dailyGoalUnit, model.annualBookGoal, model.uncertaintyMinutes, model.timezoneID)
        model.dailyGoalUnit = dailyUnitDraft
        model.annualBookGoal = annualEnabledDraft ? Int(annualGoalDraft) : nil
        model.pageGoal = Double(pageGoal)
        model.goalMinutes = Double(goal)
        model.uncertaintyMinutes = Double(uncertainty)
        model.timezoneID = timezoneDraft
        model.saveSettings()
        if model.errorMessage != nil {
            model.pageGoal = previous.0; model.goalMinutes = previous.1; model.dailyGoalUnit = previous.2
            model.annualBookGoal = previous.3; model.uncertaintyMinutes = previous.4; model.timezoneID = previous.5
        } else { reloadReadingDrafts() }
        showResult(success: "Reading settings applied.")
    }

    private func applyDiscordDrafts() {
        model.discordApplicationID = discordApplicationIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.discordAssetKey = discordAssetKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveSettings()
        if model.errorMessage == nil { reloadDiscordDrafts() }
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
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
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
                .foregroundStyle(ReadingPalette.moss)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            control()
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 15)
    }
}

private extension SettingsView {
    @ViewBuilder
    func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .font(.callout).foregroundStyle(.secondary)
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
