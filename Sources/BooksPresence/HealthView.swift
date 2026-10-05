import SwiftUI
import BooksCore

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
