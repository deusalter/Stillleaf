import SwiftUI
import BooksCore

@MainActor
struct FinishedBookTimeline: View {
    @ObservedObject var model: AppModel
    var search = ""
    var showsHeading = true
    /// Opens book details, where rating and reading dates are edited.
    var present: (DashboardSheet) -> Void = { _ in }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.timeZone = TimeZone(identifier: model.timezoneID) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var entries: [FinishedBookEntry] {
        model.finishedBooks
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.author ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { lhs, rhs in
                switch (lhs.finishedAt, rhs.finishedAt) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    let order = lhs.title.localizedStandardCompare(rhs.title)
                    return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
                }
            }
    }

    private var years: [FinishedTimelineYear] {
        Dictionary(grouping: entries.compactMap { entry -> (Int, FinishedBookEntry)? in
            guard let date = entry.finishedAt else { return nil }
            return (calendar.component(.year, from: date), entry)
        }, by: \.0)
        .map { year, values in
            FinishedTimelineYear(year: year, entries: values.map(\.1))
        }
        .sorted { $0.year > $1.year }
    }

    private var undatedEntries: [FinishedBookEntry] {
        entries.filter { $0.finishedAt == nil }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 40) {
            if showsHeading {
                PageHeader("Finished", subtitle: nil)
            }
            if entries.isEmpty {
                Text(search.isEmpty ? "Books marked finished in Apple Books will appear here." : "No finished books match your search.")
                    .foregroundStyle(ReadingPalette.secondaryInk).padding(.vertical, 28)
            }
            ForEach(years) { year in
                yearGroup(title: String(year.year), note: "\(year.entries.count) \(year.entries.count == 1 ? "book" : "books")", entries: year.entries)
            }
            if !undatedEntries.isEmpty {
                yearGroup(title: "Date unavailable",
                          note: "These completion records have no saved finish date, so they appear after the dated timeline.",
                          entries: undatedEntries)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(ReadingButtonStyle())
    }

    /// Book details for a finished entry, even when its journal record is missing.
    static func sheet(for entry: FinishedBookEntry, books: [BookRecord]) -> DashboardSheet {
        .book(books.first { $0.id == entry.id } ?? BookRecord(id: entry.id, title: entry.title, author: entry.author))
    }

    private func yearGroup(title: String, note: String, entries: [FinishedBookEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ReadingType.numeral(30)).foregroundStyle(ReadingPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                Text(note).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    .multilineTextAlignment(.trailing)
            }
            Hairline().padding(.bottom, 6)
            ForEach(entries) { entry in
                FinishedBookTimelineRow(model: model, entry: entry, calendar: calendar, present: present)
            }
        }
    }
}

@MainActor
struct ReadingTimelineView: View {
    @ObservedObject var model: AppModel
    var present: (DashboardSheet) -> Void = { _ in }
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageHeader("Timeline", subtitle: nil) {
                    TextField("Find a finished title or author", text: $search)
                        .textFieldStyle(ReadingTextFieldStyle())
                        .frame(width: 260)
                }
                FinishedBookTimeline(model: model, search: search, showsHeading: false, present: present)
            }
            .readingPage(maxWidth: 860)
        }
        .buttonStyle(ReadingButtonStyle())
    }
}

private struct FinishedTimelineYear: Identifiable {
    let year: Int
    let entries: [FinishedBookEntry]
    var id: Int { year }
}

/// One finished book. The whole row opens book details, where rating and dates are edited.
@MainActor
private struct FinishedBookTimelineRow: View {
    @ObservedObject var model: AppModel
    let entry: FinishedBookEntry
    let calendar: Calendar
    let present: (DashboardSheet) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var book: BookRecord? { model.books.first { $0.id == entry.id } }

    var body: some View {
        Button {
            present(FinishedBookTimeline.sheet(for: entry, books: model.books))
        } label: {
            HStack(alignment: .center, spacing: 20) {
                dateColumn.frame(width: 56, alignment: .leading)
                BookCoverView(book: book, size: .timeline)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title)
                        .font(ReadingType.bookTitle(20))
                        .foregroundStyle(ReadingPalette.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let author = entry.author, !author.isEmpty {
                        Text(author).font(.callout).foregroundStyle(ReadingPalette.secondaryInk).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        RatingStars(rating: model.rating(for: entry.id))
                        Text(entry.imported ? "Imported history" : entry.source)
                            .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReadingPalette.secondaryInk)
                    .opacity(hovering || focused ? 1 : 0.5)
            }
            .padding(.vertical, 12).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? ReadingPalette.surface : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? ReadingPalette.accent : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : ReadingMotion.hover, value: hovering)
        .padding(.horizontal, -12)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open book details to rate or edit reading dates")
    }

    private var dateColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let date = entry.finishedAt {
                Text(calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1] + " " + String(calendar.component(.day, from: date)))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ReadingPalette.ink)
                Text(calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
                    .font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        let finished = entry.finishedAt.map { "finished \(formattedDate($0))" } ?? "finish date unavailable"
        let rating = model.rating(for: entry.id).map { ", rated \($0.formatted(.number.precision(.fractionLength(0...2)))) of 5" } ?? ", not rated"
        return "\(entry.title)\(entry.author.map { " by \($0)" } ?? ""), \(finished)\(rating)"
    }

    private func formattedDate(_ date: Date) -> String {
        let month = calendar.monthSymbols[calendar.component(.month, from: date) - 1]
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        return "\(month) \(day), \(year)"
    }
}
