import Foundation
import UserNotifications

// MARK: - EarningsNotificationManager
// Schedules a local notification the day before each upcoming earnings report.
// Weekly re-check detects date changes and reschedules accordingly.

@MainActor
final class EarningsNotificationManager {

    static let shared = EarningsNotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    // UserDefaults keys
    private let lastCheckKey  = "earnings_notif_last_check_v1"
    private let scheduledKey  = "earnings_notif_scheduled_v1"   // [notifId: isoDateString]

    private let checkInterval: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    // MARK: - Public API

    /// Schedules earnings notifications for all upcoming events.
    /// Skips re-checking if called within the last 7 days, unless `force` is true.
    func scheduleIfNeeded(
        events: [EarningsEvent],
        prefs: NotificationPreferencesManager,
        force: Bool = false
    ) async {
        guard prefs.earningsAlertsEnabled else { cancelAll(); return }

        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(lastCheck) > checkInterval else { return }

        await scheduleAll(events: events, prefs: prefs)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    /// Cancels all pending earnings notifications then reschedules from scratch.
    func scheduleAll(events: [EarningsEvent], prefs: NotificationPreferencesManager) async {
        guard prefs.earningsAlertsEnabled else { cancelAll(); return }

        let stored = UserDefaults.standard.dictionary(forKey: scheduledKey) as? [String: String] ?? [:]
        var updated: [String: String] = [:]

        let upcoming = events.filter { $0.isUpcoming }

        for event in upcoming {
            guard !prefs.isMuted(event.symbol) else { continue }

            let notifId = notificationId(for: event)
            let dateStr = isoDateString(event.date)
            updated[notifId] = dateStr

            // Same date already scheduled — nothing to do
            if stored[notifId] == dateStr { continue }

            // Date changed or new event — cancel old, schedule fresh
            center.removePendingNotificationRequests(withIdentifiers: [notifId])

            guard let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: event.date),
                  dayBefore > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Earnings Tomorrow: \(event.symbol)"
            let quarterLabel = event.quarter.isEmpty ? "" : " (\(event.quarter))"
            content.body = "\(event.symbol)\(quarterLabel) reports earnings tomorrow."
            content.sound = .default
            content.userInfo = ["symbol": event.symbol, "type": "earnings"]

            var comps = Calendar.current.dateComponents([.year, .month, .day], from: dayBefore)
            comps.hour   = 8
            comps.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request  = UNNotificationRequest(identifier: notifId, content: content, trigger: trigger)
            try? await center.add(request)
        }

        UserDefaults.standard.set(updated, forKey: scheduledKey)
    }

    /// Cancels all pending earnings notifications and clears stored schedule.
    func cancelAll() {
        let stored = UserDefaults.standard.dictionary(forKey: scheduledKey) as? [String: String] ?? [:]
        center.removePendingNotificationRequests(withIdentifiers: Array(stored.keys))
        UserDefaults.standard.removeObject(forKey: scheduledKey)
    }

    // MARK: - Helpers

    private func notificationId(for event: EarningsEvent) -> String {
        "earnings_\(event.symbol)_\(isoDateString(event.date))"
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
