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

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    let present: (DashboardSheet) -> Void
    let deleteAll: () -> Void
    let uninstall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "Settings", subtitle: "Tracking stays local unless you choose to export or enable Discord sharing.")
                settingsForm
                GroupBox("Data") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Exports and backups contain your local reading history. Import is duplicate-safe; restore replaces the local database after validation. Delete all data removes managed backups and cached covers, while files saved outside BooksPresence remain your responsibility.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Export JSON") { model.exportJSON() }
                            Button("Export CSV") { model.exportCSV() }
                            Button("Import JSON") { model.importJSON() }
                        }
                        HStack {
                            Button("Create backup") { model.backup() }
                            Button("Restore backup") { present(.restore) }
                        }
                        Divider().padding(.vertical, 3)
                        HStack {
                            Button("Delete all reading data", role: .destructive, action: deleteAll)
                            Button("Uninstall", role: .destructive, action: uninstall)
                        }
                    }.padding(.top, 4)
                }
                GroupBox("Accessibility") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Automatic capture needs macOS Accessibility permission. Missing permission is recorded as a health issue and tracking fails closed.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Request access") { model.requestAccessibility() }
                            Button("Open Accessibility settings") { model.openAccessibilitySettings() }
                        }
                    }.padding(.top, 4)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Tracking") {
                Toggle("Enable tracking", isOn: $model.trackingEnabled)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Stepper(value: $model.goalMinutes, in: 1...240, step: 1) {
                    Text("Daily goal: \(Int(model.goalMinutes)) minutes")
                }
                TextField("Calendar timezone", text: $model.timezoneID)
                Stepper(value: $model.uncertaintyMinutes, in: 1...180, step: 1) {
                    Text("Review time after \(Int(model.uncertaintyMinutes)) minutes without evidence")
                }
                Text("Goal changes apply today and future days. Historic goal qualification is retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Discord Rich Presence") {
                Toggle("Share current activity with Discord", isOn: $model.discordEnabled)
                TextField("Application ID", text: $model.discordApplicationID)
                TextField("Fallback asset key", text: $model.discordAssetKey)
                Text(model.discordStatus).font(.caption).foregroundStyle(.secondary)
                Text("Discord sharing is independent of local tracking. A book can also be excluded from sharing in its details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Save settings") { model.saveSettings() }.buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .tint(ReadingPalette.moss)
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
