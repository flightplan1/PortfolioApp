import Foundation
import UserNotifications

// MARK: - Options Notification Manager
// Schedules local expiry alerts at 14d, 7d, 3d before expiry and on expiry day (9:00 AM local).

@MainActor
final class OptionsNotificationManager {

    static let shared = OptionsNotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    // MARK: - Authorization

    /// Requests notification permission. Returns true if granted.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Schedule

    /// Schedules expiry alert notifications for an options holding.
    /// Any existing notifications for this holding are cancelled first.
    func scheduleExpiryNotifications(for holding: Holding) async {
        guard holding.isOption,
              let expiryDate = holding.expiryDate,
              expiryDate > Date() else { return }

        cancelNotifications(for: holding)

        let symbol = holding.symbol
        let baseId = holding.id.uuidString

        let schedule: [(daysBeforeExpiry: Int, message: String)] = [
            (14, "\(symbol) option expires in 14 days — review your position."),
            (7,  "\(symbol) option expires in 7 days — review your position."),
            (3,  "\(symbol) option expires in 3 days — action required."),
            (0,  "\(symbol) option expires today — close or let it expire.")
        ]

        for item in schedule {
            guard let fireDate = alertDate(expiryDate: expiryDate, daysBeforeExpiry: item.daysBeforeExpiry),
                  fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Option Expiry Alert"
            content.body = item.message
            content.sound = .default
            content.userInfo = ["holdingId": baseId, "symbol": symbol]

            var components = Calendar.current.dateComponents([.year, .month, .day], from: fireDate)
            components.hour = 9
            components.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: notificationId(holdingId: baseId, days: item.daysBeforeExpiry),
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Cancels all pending expiry notifications for the given holding.
    func cancelNotifications(for holding: Holding) {
        let baseId = holding.id.uuidString
        let ids = [0, 3, 7, 14].map { notificationId(holdingId: baseId, days: $0) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Reschedules expiry notifications for all options in the given list.
    func rescheduleAll(holdings: [Holding]) async {
        for holding in holdings where holding.isOption {
            await scheduleExpiryNotifications(for: holding)
        }
    }

    // MARK: - Helpers

    private func alertDate(expiryDate: Date, daysBeforeExpiry: Int) -> Date? {
        if daysBeforeExpiry == 0 {
            return Calendar.current.startOfDay(for: expiryDate)
        }
        return Calendar.current.date(byAdding: .day, value: -daysBeforeExpiry, to: expiryDate)
    }

    private func notificationId(holdingId: String, days: Int) -> String {
        "\(holdingId)_expiry_\(days)d"
    }
}
