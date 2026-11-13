import Foundation

/// The optional daily reminder: when it should fire and what it says. Nothing here touches the
/// notification system, so the rule can be tested on its own; `ReminderScheduler` applies it.
enum ReadingReminder {
    static let enabledKey = "reminderEnabled"
    /// Minutes after midnight, local time.
    static let minutesKey = "reminderMinutes"
    static let defaultMinutes = 20 * 60
    static let title = "Time to read"
    /// Reminders are planned this many days ahead and replanned whenever the app is used.
    static let horizon = 7

    struct Planned: Equatable {
        let date: Date
        let body: String
    }

    /// The reminders from `now` on. Today's is dropped once its time has passed or today's goal is reached:
    /// a reminder is for a day whose reading is still open.
    static func plan(now: Date, minutes: Int, goalReached: Bool, streak: Int, calendar: Calendar = .current) -> [Planned] {
        let minutes = min(24 * 60 - 1, max(0, minutes))
        let today = calendar.startOfDay(for: now)
        return (0..<horizon).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) else { return nil }
            if offset == 0 {
                guard date > now, !goalReached else { return nil }
                return Planned(date: date, body: streak > 0 ? "Read today to keep your \(streak)-day streak." : "Today's reading goal is still open.")
            }
            return Planned(date: date, body: "Your book is where you left it.")
        }
    }
}
