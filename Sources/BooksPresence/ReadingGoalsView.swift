import SwiftUI
import BooksCore

extension DailyGoalProgress {
    var unitTitle: String { unit == .pages ? "pages" : "minutes" }
    var displayValue: String { value > 0 && value < 1 ? "<1" : Int(value).formatted() }
    var todayLabel: String { unit == .pages ? (value == 1 ? "page today" : "pages today") : "minutes today" }
    var targetText: String { target.map { "\(Int($0)) \(unitTitle)" } ?? "No goal set" }
    var summary: String { target.map { "\(displayValue) / \(Int($0)) \(unitTitle)" } ?? "\(displayValue) \(unitTitle) · no goal" }
    var goalDetail: String {
        guard let target else { return "Choose your daily goal in Settings." }
        if value > target { return "\(Int(value - target)) \(unitTitle) beyond your daily goal." }
        return reached ? "You reached your \(targetText) goal." : "Your daily goal is \(targetText)."
    }
    var goalTitle: String {
        guard let target else { return "A little reading, every day." }
        if reached { return "A good day for reading." }
        if value == 0 { return "Your next chapter awaits." }
        return "\(Int(ceil(max(0, target - value)))) \(unitTitle) to your goal."
    }
}

struct AnnualReadingGoalView: View {
    @ObservedObject var model: AppModel
    let openBook: (BookRecord) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        guard let target = model.annualBookGoal, target > 0 else { return 0 }
        return min(1, Double(model.annualBooksFinished) / Double(target))
    }
    private var recentBooks: [BookRecord] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: model.timezoneID) ?? .current
        return model.finishedBooks.filter { entry in
            entry.finishedAt.map { $0 <= Date() && calendar.component(.year, from: $0) == model.goalYear } ?? false
        }.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(5).compactMap { entry in model.books.first { $0.id == entry.id } }
    }
    private var detail: String {
        guard let target = model.annualBookGoal else { return "Set a goal for the books you want to make time for." }
        let remaining = max(0, target - model.annualBooksFinished)
        return remaining == 0 ? "Your yearly goal is complete." : "\(remaining) more \(remaining == 1 ? "book" : "books") to your goal."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your \(String(model.goalYear)) in books").font(ReadingType.bookTitle(25))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(model.annualBooksFinished)").font(ReadingType.numeral(34)).monospacedDigit()
                        if let target = model.annualBookGoal {
                            Text("/ \(target)").font(ReadingType.numeral(21)).foregroundStyle(ReadingPalette.secondaryInk)
                        }
                    }
                    Text("Books finished").font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Your \(String(model.goalYear)) reading year")
                .accessibilityValue(model.annualBookGoal.map { "\(model.annualBooksFinished) of \($0) books finished. \(detail)" } ?? "\(model.annualBooksFinished) books finished, no yearly goal")
            }
            if recentBooks.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "books.vertical").font(.system(size: 36, weight: .light)).foregroundStyle(ReadingPalette.accent)
                    Text("Mark a book finished to add it to your reading year.")
                        .font(.callout).foregroundStyle(ReadingPalette.secondaryInk)
                }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recentBooks) { book in
                        Button { openBook(book) } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                BookCoverView(book: book, size: .annual)
                                Text(book.title).font(.caption.weight(.medium)).foregroundStyle(ReadingPalette.ink)
                                    .lineLimit(2).frame(width: 92, alignment: .leading)
                            }
                            .frame(width: 92, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open book details for \(book.title)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 12) {
                if model.annualBookGoal != nil {
                    GeometryReader { geometry in
                        Capsule().fill(ReadingPalette.progressTrack)
                            .overlay(alignment: .leading) {
                                Capsule().fill(ReadingPalette.accent).frame(width: geometry.size.width * progress)
                            }
                    }.frame(height: 5)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(detail).font(.caption).foregroundStyle(ReadingPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(model.annualBookGoal == nil ? "Set goal" : "Edit goal") {
                        model.showDashboard(section: .settings, settingsCategory: .reading)
                    }.controlSize(.small)
                    Button("View timeline") { model.showDashboard(section: .timeline) }.controlSize(.small)
                }
            }
        }
        .padding(24)
        .background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .help("Books with a confirmed finish date in this calendar year. Undated books are not counted.")
    }
}
