import Foundation
import UserNotifications

/// Schedules the daily reminder as local notifications. They are made on this device from the plan in
/// `ReadingReminder`; nothing is sent to a server, and nothing is scheduled unless the reader turned it on.
@MainActor
enum ReminderScheduler {
    private static var identifiers: [String] { (0..<ReadingReminder.horizon).map { "reading-reminder-\($0)" } }

    /// Asks for permission to show notifications. Returns whether the reader allowed them.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replans the coming days: after a setting changes, when reading reaches the goal, and whenever the
    /// app comes or goes. Does nothing while the reminder is off.
    static func refresh(journal: Journal, defaults: UserDefaults = .standard, now: Date = Date()) {
        guard defaults.bool(forKey: ReadingReminder.enabledKey) else { return }
        let minutes = defaults.object(forKey: ReadingReminder.minutesKey) as? Int ?? ReadingReminder.defaultMinutes
        let plan = ReadingReminder.plan(now: now, minutes: minutes, goalReached: journal.todayGoal.reached,
                                        streak: journal.history.dailyGoalStreak.current)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for (index, planned) in plan.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = ReadingReminder.title
            content.body = planned.body
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: planned.date)
            center.add(UNNotificationRequest(identifier: identifiers[index], content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
