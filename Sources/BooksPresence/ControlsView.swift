import SwiftUI
import BooksCore

@MainActor
struct ManualStartView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start manual reading").font(.system(.title2, design: .serif))
            Text("Use this for a paper book or intentional side-by-side reading. It is stored as manual activity.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Book title", text: $title)
                TextField("Author (optional)", text: $author)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start reading") {
                    model.startManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
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
        VStack(spacing: 0) {
            HStack {
                Text("Add manual reading").font(.system(.title2, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
            }.padding(20)
            Divider()
            Form {
                Section("Book") {
                    TextField("Title", text: $title)
                    TextField("Author (optional)", text: $author)
                }
                Section("Time") {
                    DatePicker("Started", selection: $start)
                    DatePicker("Finished", selection: $end, in: start...)
                    Text("The entry is marked manual. It does not represent Apple Books activity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Add reading time") {
                    model.addManual(title: title.trimmingCharacters(in: .whitespacesAndNewlines), author: author.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start)
            }
            .formStyle(.grouped).padding(.vertical, 8)
        }
        .frame(width: 480, height: 410)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
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
            Text("Merge book identities").font(.system(.title2, design: .serif))
            Text("Merge \(source.title) into a selected record. Its recorded time will be shown with that record; you can reverse this decision later with Unmerge.")
                .font(.callout).foregroundStyle(.secondary)
            if targets.isEmpty {
                Text("There is no other book record available to merge with.").foregroundStyle(.secondary)
            } else {
                Picker("Merge into", selection: $targetID) {
                    Text("Choose a book").tag("")
                    ForEach(targets) { target in Text(target.title).tag(target.id) }
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
                    .buttonStyle(.borderedProminent).disabled(targetID.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
    }
}

@MainActor
struct HealthView: View {
    @ObservedObject var model: AppModel
    private var outages: [AuditEvent] {
        model.events.filter {
            let value = $0.kind.lowercased()
            return value.contains("outage") || value.contains("gap") || value.contains("capture") || value.contains("permission") || value.contains("recovery") || value.contains("clock")
        }.sorted { $0.date > $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Data health", subtitle: "A day with zero recorded reading is not treated as a tracking outage.")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Current capture state").font(.system(.title2, design: .serif))
                    Text(model.health.isEmpty ? "No current health message has been recorded." : model.health)
                    Text("Last successful capture: \(ReadingFormat.date(model.lastCapture))")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Request Accessibility access") { model.requestAccessibility() }
                        Button("Open Accessibility settings") { model.openAccessibilitySettings() }
                        Button("Refresh") { model.refresh() }
                    }
                }
                .readingPanel()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recorded tracking gaps, recoveries, and failures").font(.system(.title2, design: .serif))
                    if outages.isEmpty {
                        Text("No outages or capture failures are recorded. This does not mean no reading occurred during unobserved time.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(outages) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.kind).font(.headline)
                                Text(ReadingFormat.date(event.date)).font(.caption).foregroundStyle(.secondary)
                                Text(event.detail).font(.callout)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
                .readingPanel()
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {
    case reading = "Reading"
    case discord = "Discord"
    case data = "Data"

    var id: String { rawValue }

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
    @State private var didLoadDrafts = false
    @State private var goalDraft = "20"
    @State private var uncertaintyDraft = "20"
    @State private var timezoneDraft = TimeZone.current.identifier
    @State private var timezoneSearch = ""
    @State private var discordApplicationIDDraft = ""
    @State private var discordAssetKeyDraft = "books"
    @State private var applyFeedback: String?
    @State private var applyFailed = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: "Settings", subtitle: "Tracking stays local unless you choose to export or enable Discord sharing.")
                settingsLayout
            }
            .padding(32)
            .frame(maxWidth: 1_060, alignment: .leading)
        }
        .background(ReadingPalette.paper)
        .tint(ReadingPalette.moss)
        .onAppear(perform: loadDraftsIfNeeded)
    }

    private var settingsLayout: some View {
        VStack(alignment: .leading, spacing: 18) {
            categoryPicker
            categoryDetail
        }
        .frame(minWidth: 650, maxWidth: .infinity, alignment: .leading)
    }

    private var categoryPicker: some View {
        Picker("Settings category", selection: $category) {
            ForEach(SettingsCategory.allCases) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Settings category")
    }

    @ViewBuilder
    private var categoryDetail: some View {
        switch category {
        case .reading: readingSettings
        case .discord: discordSettings
        case .data: dataSettings
        }
    }

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeading(title: "Reading", subtitle: "Choose what BooksPresence captures and how it arranges your reading day.")
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "book.closed.fill", title: "Enable reading tracking", description: "Capture eligible Apple Books activity on this Mac.") {
                        Toggle("Enable reading tracking", isOn: trackingBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Enable reading tracking")
                    }
                    settingDivider
                    SettingRow(icon: "rectangle.and.arrow.up.right.and.arrow.down.left", title: "Launch at login", description: "Start BooksPresence when you sign in to this Mac.") {
                        Toggle("Launch at login", isOn: launchAtLoginBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Launch BooksPresence at login")
                    }
                }
            }

            SettingsSectionHeading(title: "Reading day", subtitle: "Choose values, then apply them when you are ready.")
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "target", title: "Daily goal", description: "Goal changes apply today and future days; historic qualifications stay intact.") {
                        numericEditor(label: "Daily goal minutes", value: $goalDraft, range: 1...1_440, stepperValue: goalBinding)
                    }
                    HStack(spacing: 6) {
                        Text("Quick goals").font(.caption).foregroundStyle(.secondary)
                        ForEach([15, 20, 30, 45, 60], id: \.self) { minutes in
                            Button("\(minutes)m") { setGoalPreset(minutes) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                    .padding(.leading, 44)
                    .padding(.bottom, 13)
                    Text("Choose 1–1,440 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 44)
                        .padding(.bottom, 13)
                    settingDivider
                    SettingRow(icon: "clock.badge.checkmark", title: "Review after", description: "Mark time for review after this many minutes without fresh evidence.") {
                        numericEditor(label: "Review threshold minutes", value: $uncertaintyDraft, range: 1...240, stepperValue: uncertaintyBinding)
                    }
                    Text("Choose 1–240 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 44)
                        .padding(.bottom, 13)
                    settingDivider
                    SettingRow(icon: "globe.americas", title: "Calendar time zone", description: "Controls the calendar day boundary and daily totals.") {
                        EmptyView()
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        TextField("Search time zones", text: $timezoneSearch)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search time zones")
                        Picker("Calendar time zone", selection: $timezoneDraft) {
                            ForEach(timezoneChoices, id: \.self) { identifier in
                                Text(timezoneDisplayName(for: identifier)).tag(identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Showing matching IANA time zones. Search by city, region, or identifier.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 44)
                    .padding(.trailing, 2)
                    .padding(.bottom, 14)
                }
            }
            applyBar(action: { applyReadingDrafts() }, label: "Apply reading changes", valid: readingDraftsAreValid)

            SettingsSectionHeading(title: "Accessibility", subtitle: "Automatic capture needs macOS permission. The status below reflects the access currently granted to BooksPresence.")
            settingsCard {
                if model.accessibilityGranted {
                    SettingRow(icon: "checkmark.shield.fill", title: "Accessibility access granted", description: "BooksPresence can automatically check eligible Apple Books activity while tracking is on.") {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(ReadingPalette.moss)
                    }
                } else {
                    SettingRow(icon: "accessibility", title: "Accessibility access needed", description: "Automatic capture is unavailable until you allow BooksPresence in macOS Privacy settings.") {
                        HStack(spacing: 8) {
                            Button("Request access") { model.requestAccessibility() }
                            Button("Open settings") { model.openAccessibilitySettings() }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var discordSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeading(title: "Discord", subtitle: "Sharing is optional and stays separate from local reading tracking.")
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "person.2.wave.2", title: "Share current activity", description: "Show your current eligible book as Discord Rich Presence.") {
                        Toggle("Share current activity with Discord", isOn: discordBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Share current activity with Discord")
                    }
                    settingDivider
                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(icon: "key.horizontal", title: "Application ID", description: "The Discord application used for your presence.") {
                            TextField("Application ID", text: $discordApplicationIDDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 210)
                                .onSubmit { applyDiscordDrafts() }
                        }
                        SettingRow(icon: "photo", title: "Fallback asset key", description: "Generic artwork uploaded to your Discord application. Local covers stay on this Mac.") {
                            TextField("Fallback asset key", text: $discordAssetKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .onSubmit { applyDiscordDrafts() }
                        }
                    }
                    .padding(.vertical, 2)
                    if model.discordNeedsSetup {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Discord sharing needs an Application ID before it can show your activity.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(ReadingPalette.moss)
                            Link("Open Discord Developer Portal", destination: URL(string: "https://discord.com/developers/applications")!)
                                .font(.caption)
                        }
                        .padding(.leading, 44)
                        .padding(.bottom, 13)
                    } else if !model.discordEnabled {
                        Label("Sharing is off. You can configure Discord now, then turn sharing on when you are ready.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 44)
                            .padding(.bottom, 13)
                    }
                    settingDivider
                    SettingRow(icon: "dot.radiowaves.left.and.right", title: "Connection status", description: "See the current Discord connection state.") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.discordStatus)
                            if let result = model.lastDiscordResult {
                                Text("Last result: \(result)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 245, alignment: .trailing)
                    }
                }
            }
            applyBar(action: { applyDiscordDrafts() }, label: "Apply Discord details", valid: true)
            Text("A paused card stays visible for up to 20 minutes after your last page turn or reading activity. A book can be excluded from Discord sharing in its details without excluding it from local tracking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var dataSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeading(title: "Data", subtitle: "Your history stays on this Mac. Exports and chosen backup locations are the copies you control.")
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "square.and.arrow.up", title: "Export reading history", description: "Save a portable JSON archive or CSV tables to a folder you choose.") {
                        HStack(spacing: 8) {
                            Button("Export JSON") { model.exportJSON() }
                            Button("Export CSV") { model.exportCSV() }
                        }
                        .controlSize(.small)
                    }
                    settingDivider
                    SettingRow(icon: "square.and.arrow.down", title: "Import history", description: "Import a JSON archive. Existing records are checked to avoid duplicates.") {
                        Button("Import JSON") { model.importJSON() }
                            .controlSize(.small)
                    }
                    settingDivider
                    SettingRow(icon: "externaldrive.badge.plus", title: "Backup and restore", description: "A restore validates the selected backup and replaces the local database.") {
                        HStack(spacing: 8) {
                            Button("Create backup") { model.backup() }
                            Button("Restore backup") { present(.restore) }
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSectionHeading(title: "Remove from this Mac", subtitle: "Delete all data asks for confirmation. Files exported outside BooksPresence stay where you saved them.")
            settingsCard {
                VStack(spacing: 0) {
                    SettingRow(icon: "trash", title: "Delete all reading data", description: "Remove local reading history, managed backups, and cached covers.") {
                        Button("Delete all data", role: .destructive, action: deleteAll)
                            .controlSize(.small)
                    }
                    settingDivider
                    SettingRow(icon: "app.dashed", title: "Uninstall BooksPresence", description: "Remove the installed app after you have saved any history you want to keep.") {
                        Button("Uninstall", role: .destructive, action: uninstall)
                            .controlSize(.small)
                    }
                }
            }
        }
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { enabled in
            model.launchAtLogin = enabled
            model.saveSettings()
            showResult(success: enabled ? "Launch at login enabled." : "Launch at login disabled.")
        })
    }

    private var goalBinding: Binding<Int> {
        Binding(get: { Int(goalDraft) ?? 20 }, set: { value in
            goalDraft = String(value)
            clearFeedback()
        })
    }

    private var uncertaintyBinding: Binding<Int> {
        Binding(get: { Int(uncertaintyDraft) ?? 20 }, set: { value in
            uncertaintyDraft = String(value)
            clearFeedback()
        })
    }

    private var timezoneChoices: [String] {
        let query = timezoneSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = TimeZone.knownTimeZoneIdentifiers.filter { identifier in
            guard !query.isEmpty else { return true }
            return identifier.lowercased().contains(query)
                || (TimeZone(identifier: identifier)?.localizedName(for: .standard, locale: .current)?.lowercased().contains(query) ?? false)
        }
        return matching.contains(timezoneDraft) ? matching : [timezoneDraft] + matching
    }

    private func timezoneDisplayName(for identifier: String) -> String {
        let localized = TimeZone(identifier: identifier)?.localizedName(for: .standard, locale: .current)
        return localized.map { "\($0) — \(identifier)" } ?? identifier
    }

    private var readingDraftsAreValid: Bool {
        guard let goal = Int(goalDraft), (1...1_440).contains(goal),
              let uncertainty = Int(uncertaintyDraft), (1...240).contains(uncertainty),
              TimeZone(identifier: timezoneDraft) != nil else { return false }
        return true
    }

    @ViewBuilder
    private func numericEditor(label: String, value: Binding<String>, range: ClosedRange<Int>, stepperValue: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyReadingDrafts() }
            Text("min").font(.callout).foregroundStyle(.secondary)
            Stepper(label, value: stepperValue, in: range)
                .labelsHidden()
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private func applyBar(action: @escaping () -> Void, label: String, valid: Bool) -> some View {
        HStack(spacing: 10) {
            Button(label, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            if let applyFeedback {
                Label(applyFeedback, systemImage: applyFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(applyFailed ? ReadingPalette.ochre : ReadingPalette.moss)
            } else if !valid {
                Text("Enter a value within the shown range before applying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert drafts") { reloadDrafts() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
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

    private func loadDraftsIfNeeded() {
        guard !didLoadDrafts else { return }
        didLoadDrafts = true
        reloadDrafts()
    }

    private func reloadDrafts() {
        goalDraft = String(Int(model.goalMinutes.rounded()))
        uncertaintyDraft = String(Int(model.uncertaintyMinutes.rounded()))
        timezoneDraft = model.timezoneID
        discordApplicationIDDraft = model.discordApplicationID
        discordAssetKeyDraft = model.discordAssetKey
        timezoneSearch = ""
        clearFeedback()
    }

    private func applyReadingDrafts() {
        guard readingDraftsAreValid, let goal = Int(goalDraft), let uncertainty = Int(uncertaintyDraft) else {
            applyFeedback = "Choose a daily goal from 1–1,440 minutes, a review threshold from 1–240 minutes, and a valid time zone."
            applyFailed = true
            return
        }
        model.goalMinutes = Double(goal)
        model.uncertaintyMinutes = Double(uncertainty)
        model.timezoneID = timezoneDraft
        model.saveSettings()
        showResult(success: "Reading settings applied.")
    }

    private func applyDiscordDrafts() {
        model.discordApplicationID = discordApplicationIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.discordAssetKey = discordAssetKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveSettings()
        showResult(success: "Discord details applied.")
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
            Text(title).font(.system(.title3, design: .serif).weight(.semibold))
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
            .background(ReadingPalette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReadingPalette.border, lineWidth: 1))
    }
}

@MainActor
struct RestoreConfirmationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Restore a backup?").font(.system(.title2, design: .serif))
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
    }
}
