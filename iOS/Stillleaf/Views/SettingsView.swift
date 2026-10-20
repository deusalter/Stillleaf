import SwiftUI
import UniformTypeIdentifiers
import BooksCore

struct SettingsView: View {
    @EnvironmentObject private var journal: Journal
    let showWelcome: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                ReadingSection()
                GoalsSection()
                ReaderSection()
                Section("Calendar") {
                    NavigationLink {
                        TimeZoneChooser()
                    } label: {
                        LabeledContent("Time zone", value: journal.timezoneID.replacingOccurrences(of: "_", with: " "))
                    }
                }
                DataSection()
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Button("Show Welcome", action: showWelcome)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct ReadingSection: View {
    @EnvironmentObject private var journal: Journal

    var body: some View {
        Section {
            Toggle("Track reading time", isOn: Binding(get: { journal.trackingEnabled }, set: { journal.setTrackingEnabled($0) }))
        } header: {
            Text("Reading")
        } footer: {
            Text("Time counts only while a book is open in Stillleaf and the app is in front of you. Leaving the app, locking the screen, Control Centre or a call pause it at once. Pages count when you move forward through the book. Nothing runs in the background, and Apple Books reading on this device cannot be seen.")
        }
    }
}

private struct GoalsSection: View {
    @EnvironmentObject private var journal: Journal
    @State private var unit: DailyGoalUnit = .pages
    @State private var pages = 20
    @State private var minutes = 20
    @State private var yearly = false
    @State private var annual = 12
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Daily goal", selection: $unit) {
                Text("Pages").tag(DailyGoalUnit.pages)
                Text("Minutes").tag(DailyGoalUnit.minutes)
            }
            if unit == .pages {
                Stepper(value: $pages, in: ReadingGoalLimits.dailyPages, step: 5) { LabeledContent("Pages a day", value: "\(pages)") }
            } else {
                Stepper(value: $minutes, in: ReadingGoalLimits.dailyMinutes, step: 5) { LabeledContent("Minutes a day", value: "\(minutes)") }
            }
            Toggle("Yearly books goal", isOn: $yearly)
            if yearly {
                Stepper(value: $annual, in: ReadingGoalLimits.annualBooks) { LabeledContent("Books this year", value: "\(annual)") }
            }
            if changed {
                Button("Save Goals") { journal.saveGoals(unit: unit, pages: pages, minutes: minutes, annualBooks: yearly ? annual : nil) }
            }
        } header: {
            Text("Goals")
        } footer: {
            Text("A new daily goal applies from today. Earlier days keep the goal they had.")
        }
        .onAppear(perform: load)
        .onChange(of: journal.dailyGoal) { _, _ in load() }
    }

    private var changed: Bool {
        let goal = journal.dailyGoal
        return goal?.resolvedUnit != unit || goal?.pages.map { Int($0) } != pages || goal.map { Int($0.minutes) } != minutes
            || journal.history.annualBookGoal != (yearly ? annual : nil)
    }

    private func load() {
        if let goal = journal.dailyGoal {
            unit = goal.resolvedUnit
            pages = Int(goal.pages ?? 20)
            minutes = Int(goal.minutes)
        }
        yearly = journal.history.annualBookGoal != nil
        annual = journal.history.annualBookGoal ?? annual
    }
}

private struct ReaderSection: View {
    @AppStorage(ReaderPreferences.gardenKey) private var garden = ReaderPreferences.GardenMode.animated.rawValue

    var body: some View {
        Section {
            Picker("Margin garden", selection: $garden) {
                ForEach(ReaderPreferences.GardenMode.allCases) { Text($0.label).tag($0.rawValue) }
            }
        } header: {
            Text("Reader")
        } footer: {
            Text("Living grows as you read and becomes Still with Reduce Motion or Low Power Mode. Typeface, page colour and layout are in the reader's Appearance panel.")
        }
    }
}

private struct DataSection: View {
    private enum Picking { case history, backup }

    @EnvironmentObject private var journal: Journal
    @State private var export: ExportFile?
    @State private var exportType: UTType = .json
    @State private var exportName = ""
    @State private var picking: Picking?
    @State private var confirmRestore: URL?
    @State private var confirmDeleteAll = false

    var body: some View {
        Section {
            Button("Export History (JSON)") { prepare(.json) { try journal.exportJSON() } }
            Button("Export Tables (CSV)") { prepare(.folder) { try journal.exportCSV() } }
            Button("Back Up Database") { prepare(.stillleafBackup) { try journal.backup() } }
            Button("Import History (JSON)…") { picking = .history }
            Button("Restore from Backup…") { picking = .backup }
        } header: {
            Text("Data")
        } footer: {
            Text("Exports and backups use the same formats as Stillleaf for Mac, so you can move your journal either way. Importing history merges it and skips duplicates; restoring replaces this device's journal.")
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }), document: export,
                      contentType: exportType, defaultFilename: exportName) { result in
            journal.discardExports()
            if case .failure(let error) = result { journal.notice = JournalNotice(title: "Export", message: error.localizedDescription) }
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .backup ? [.stillleafBackup, .database, .data] : [.json]) { result in
            let mode = picking
            switch result {
            case .success(let url):
                if mode == .backup { confirmRestore = url } else { journal.importJSON(from: url) }
            case .failure(let error):
                journal.notice = JournalNotice(title: "Import", message: error.localizedDescription)
            }
        }
        .confirmationDialog("Replace this device's journal?", isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
                            titleVisibility: .visible, presenting: confirmRestore) { url in
            Button("Restore Backup", role: .destructive) { journal.restore(from: url) }
        } message: { _ in
            Text("The backup is checked first. If it is valid, it replaces all reading history on this device.")
        }

        Section {
            Button("Delete All Data", role: .destructive) { confirmDeleteAll = true }
                .confirmationDialog("Delete everything on this device?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                    Button("Delete All Data", role: .destructive) { journal.deleteAllData() }
                } message: {
                    Text("Your reading history, reviews, imported books, notes and highlights are permanently removed. Exports you saved elsewhere are not affected.")
                }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Stillleaf has no account, makes no network requests and collects no data. Your journal and books stay in this app's storage and in your device backups.")
        }
    }

    private func prepare(_ type: UTType, _ make: () throws -> URL) {
        do {
            let url = try make()
            exportType = type
            exportName = url.lastPathComponent
            export = ExportFile(url: url)
        } catch {
            journal.notice = JournalNotice(title: "Export", message: error.localizedDescription)
        }
    }
}

private struct TimeZoneChooser: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var choice: String?

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(zones, id: \.self) { zone in
            Button {
                choice = zone
            } label: {
                HStack {
                    Text(zone.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                    Spacer()
                    if zone == journal.timezoneID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Time Zone")
        .confirmationDialog("Group history by \(choice ?? "")?", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                            titleVisibility: .visible, presenting: choice) { zone in
            Button("Change Time Zone") { if journal.setTimezone(zone) { dismiss() } }
        } message: { _ in
            Text("Days, streaks and goals are recalculated in this time zone. Recorded sessions are unchanged.")
        }
    }
}
