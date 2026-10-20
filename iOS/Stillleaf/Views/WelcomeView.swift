import SwiftUI
import BooksCore

/// First launch: what Stillleaf records, where data lives, and a daily goal. Every step can be skipped.
struct WelcomeView: View {
    @EnvironmentObject private var journal: Journal
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void
    @State private var unit: DailyGoalUnit = .pages
    @State private var amount = 20

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageleafMark().fill(Color.accentColor).frame(width: 64, height: 64).frame(maxWidth: .infinity)
                Text("Welcome to Stillleaf")
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                point("book", "Read EPUBs here", "Import DRM-free EPUBs from Files, or share them to Stillleaf from Mail, Safari or AirDrop.")
                point("clock", "Time that counts", "Reading time is recorded only while a book is open in front of you. Nothing runs in the background.")
                point("lock", "Yours, on this device", "No account and no network. Export your journal any time, in the same format as Stillleaf for Mac.")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Daily goal").font(.headline)
                    Picker("Unit", selection: $unit) {
                        Text("Pages").tag(DailyGoalUnit.pages)
                        Text("Minutes").tag(DailyGoalUnit.minutes)
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $amount, in: 5...300, step: 5) {
                        Text(unit == .pages ? ReadingText.pages(amount) : "\(amount) minutes").monospacedDigit()
                    }
                }
                Button {
                    let pages = unit == .pages ? amount : Int(journal.dailyGoal?.pages ?? 20)
                    let minutes = unit == .minutes ? amount : Int(journal.dailyGoal?.minutes ?? 20)
                    journal.saveGoals(unit: unit, pages: pages, minutes: minutes, annualBooks: journal.history.annualBookGoal)
                    done()
                    dismiss()
                } label: {
                    Text("Start Reading").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Skip") { done(); dismiss() }.frame(maxWidth: .infinity)
            }
            .padding(28)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
