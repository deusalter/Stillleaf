import SwiftUI

struct BookReviewSection: View {
    @ObservedObject var model: AppModel
    let bookID: String
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your review").font(.headline)
                    Text("Just for your journal. Always optional.").font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                }
                Spacer()
                Button(model.review(for: bookID) == nil ? "Write a review" : "Edit review") { editing = true }.controlSize(.small)
            }
            if let review = model.review(for: bookID) {
                Text(review).font(.callout).lineSpacing(4).lineLimit(6).textSelection(.enabled)
                Button("Read or edit full review") { editing = true }.controlSize(.small)
            }
        }.readingPanel()
        .sheet(isPresented: $editing) { BookReviewEditor(model: model, bookID: bookID).readingMotionAccessibility() }
    }
}

struct BookReviewEditor: View {
    @ObservedObject var model: AppModel
    let bookID: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saveError: String?
    @State private var dialog: ReviewDialog?
    private let original: String
    private var isDirty: Bool { draft != original }
    private enum ReviewDialog { case clear, discard }
    init(model: AppModel, bookID: String) {
        self.model = model; self.bookID = bookID
        original = model.review(for: bookID) ?? ""
        _draft = State(initialValue: original)
    }
    private var bookTitle: String { model.books.first { $0.id == bookID }?.title ?? "Your book" }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReadingSheetHeader(title: "Your review", subtitle: bookTitle, close: requestClose)
            Text("What stayed with you?").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Private to your journal. Included in your backups and exports; never posted online.")
                .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
            TextEditor(text: $draft)
                .font(.system(size: 14)).lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(12).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ReadingPalette.border.opacity(0.5)))
                .accessibilityLabel("Written book review")
            HStack {
                Text("\(draft.count.formatted()) / 50,000 characters").font(.caption).foregroundStyle(draft.count > 50_000 ? ReadingPalette.ochre : ReadingPalette.fadedInk)
                Spacer()
                if model.review(for: bookID) != nil {
                    Button("Clear review") { dialog = .clear }.controlSize(.small)
                }
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(ReadingPalette.ochre) }
            HStack {
                Button("Cancel", action: requestClose)
                Spacer()
                Button("Save review") {
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.review(for: bookID) != nil { dialog = .clear }
                    else { save(draft) }
                }.buttonStyle(ReadingButtonStyle(emphasis: .primary))
                    .disabled(draft.count > 50_000)
            }
        }.padding(24).frame(width: 590, height: 540)
        .background(ReadingPalette.paper).foregroundStyle(ReadingPalette.ink)
        .buttonStyle(ReadingButtonStyle())
        .interactiveDismissDisabled(isDirty)
        .onExitCommand(perform: requestClose)
        .alert(dialog == .clear ? "Clear your written review?" : "Discard this draft?",
               isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })) {
            if dialog == .clear { Button("Clear review", role: .destructive) { save(nil) } }
            else { Button("Discard draft", role: .destructive) { dismiss() } }
            Button("Keep editing", role: .cancel) { dialog = nil }
        } message: {
            Text(dialog == .clear ? "Your star rating and reading history will stay." : "Your unsaved changes will be lost. Your previously saved review will stay.")
        }
    }
    private func requestClose() {
        if isDirty { dialog = .discard } else { dismiss() }
    }

    private func save(_ value: String?) {
        model.saveReview(value, for: bookID)
        if let error = model.errorMessage { saveError = error } else { dismiss() }
    }
}
