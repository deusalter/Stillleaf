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
                .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
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
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent).textFieldStyle(ReadingTextFieldStyle())
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
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
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
        .background(ReadingPalette.canvas).foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent).textFieldStyle(ReadingTextFieldStyle())
        .buttonStyle(ReadingButtonStyle())
    }
}
