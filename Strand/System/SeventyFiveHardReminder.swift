import Foundation
import UserNotifications

// SeventyFiveHardReminder.swift - the optional evening nudge for the 75-day challenge.
//
// Local notifications only. Rather than one repeating alert that would also fire on days already
// finished, this schedules a short run of one-shot reminders: today's is included only while today still
// has open tasks. The screen calls `reschedule` whenever the checklist changes or the app comes forward,
// so the run is topped up each time the app is opened.

@MainActor
enum SeventyFiveHardReminder {

    private static let idPrefix = "seventy-five-hard-reminder-"
    /// How many days ahead reminders are queued each time the schedule is rebuilt.
    private static let horizonDays = 7

    private static var identifiers: [String] { (0..<horizonDays).map { "\(idPrefix)\($0)" } }

    /// Ask for notification permission (the system only prompts the first time) and report the answer.
    static func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    /// Remove every queued reminder.
    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Rebuild the queue. `enabled` is the user's toggle, `active` whether a run is in progress,
    /// `todayComplete` whether today's checklist is finished, `minutes` the time of day.
    static func reschedule(enabled: Bool, active: Bool, todayComplete: Bool, minutes: Int, now: Date = Date()) {
        cancel()
        guard enabled, active else { return }
        let center = UNUserNotificationCenter.current()
        let cal = Calendar.current
        let hour = min(max(minutes, 0), 24 * 60 - 1) / 60
        let minute = min(max(minutes, 0), 24 * 60 - 1) % 60
        for offset in 0..<horizonDays {
            if offset == 0 && todayComplete { continue }
            guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour
            comps.minute = minute
            guard let fire = cal.date(from: comps), fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "75 Hard"
            content.body = "Today's tasks are still open. Finish them before the day ends."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(idPrefix)\(offset)", content: content, trigger: trigger))
        }
    }
}
