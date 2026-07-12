import SwiftUI
import BooksCore

@MainActor
struct EPUBImportStatusView: View {
    @ObservedObject var controller: EPUBLibraryController
    var body: some View {
        let summary = controller.queue.summary
        VStack(alignment: .leading, spacing: 8) {
            if let error = controller.recoveryError {
                Text(error).font(.callout).foregroundStyle(ReadingPalette.ochre)
            }
            if !controller.queue.items.isEmpty {
                HStack(spacing: 10) {
                    if summary.remaining > 0 { ProgressView().controlSize(.small) }
                    Text(summary.remaining > 0 ? "Importing into Library · \(summary.remaining) remaining" : "Import complete")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if summary.remaining > 0 { Button("Cancel remaining") { controller.cancelPending() }.controlSize(.small) }
                }
                Text("\(summary.imported) added · \(summary.duplicates) already in Library · \(summary.failed) failed · \(summary.cancelled) cancelled")
                    .font(.caption).foregroundStyle(ReadingPalette.fadedInk)
                if summary.failed > 0 {
                    DisclosureGroup("Import details") {
                        ForEach(controller.queue.items.filter { $0.state == .failed }) { item in
                            Text("\(item.url.lastPathComponent): \(item.message ?? "Import failed")")
                                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if controller.queue.rejectedOverflowCount > 0 {
                            Text("The batch exceeded 1,000 files. Import the remaining files in a new batch.").font(.caption)
                        }
                    }
                }
            }
        }
        .foregroundStyle(ReadingPalette.ink)
        .accessibilityElement(children: .contain)
    }
}
