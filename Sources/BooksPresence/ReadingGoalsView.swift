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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "books.vertical").font(.system(size: 24)).foregroundStyle(ReadingPalette.moss)
            VStack(alignment: .leading, spacing: 7) {
                Text("Your \(String(model.goalYear)) reading year").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(model.annualBookGoal.map { "\(model.annualBooksFinished) of \($0) books finished" } ?? "\(model.annualBooksFinished) books finished · no yearly goal")
                    .font(.callout).foregroundStyle(ReadingPalette.fadedInk)
                if let target = model.annualBookGoal {
                    SegmentedReadingBar(progress: min(1, Double(model.annualBooksFinished) / Double(target)))
                        .frame(height: 7)
                        .animation(reduceMotion ? nil : ReadingMotion.entrance, value: model.annualBooksFinished)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(model.annualBookGoal == nil ? "Set goal" : "Edit goal") {
                model.showDashboard(section: .settings, settingsCategory: .reading)
            }.controlSize(.small)
        }.padding(20).background(ReadingPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .help("Books with a confirmed finish date in this calendar year. Undated books are not counted.")
    }
}
