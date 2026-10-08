import SwiftUI
import BooksCore

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
        .readingSheetSurface()
        .background(ReadingPalette.canvas)
        .foregroundStyle(ReadingPalette.ink)
        .tint(ReadingPalette.accent)
        .buttonStyle(ReadingButtonStyle())
    }
}
