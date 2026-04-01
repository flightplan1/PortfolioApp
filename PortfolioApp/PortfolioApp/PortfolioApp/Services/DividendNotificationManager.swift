import Foundation
import UserNotifications

// MARK: - DividendNotificationManager
// Schedules two types of local notifications:
//   1. Ex-dividend date alert — fires 2 days before the ex-div date at 9:00 AM local.
//   2. Dividend received alert — fires on the pay date at 9:00 AM local.

@MainActor
final class DividendNotificationManager {

    static let shared = DividendNotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Ex-Dividend Alert

    /// Schedules a "heads-up" notification 2 days before exDividendDate at 9:00 AM.
    /// Safe to call multiple times — cancels any existing alert for the same symbol first.
    func scheduleExDivAlert(for holding: Holding) {
        guard let exDiv = holding.lastExDividendDate,
              let alertDate = Calendar.current.date(byAdding: .day, value: -2, to: exDiv),
              alertDate > Date() else { return }

        cancelExDivAlert(for: holding)

        let id = exDivNotificationId(for: holding)
        let content = UNMutableNotificationContent()
        content.title = "\(holding.symbol) goes ex-dividend in 2 days"
        content.body  = "Shares must be held before \(exDiv.formatted(date: .abbreviated, time: .omitted)) to receive the next dividend."
        content.sound = .default

        var components = Calendar.current.dateComponents([.year, .month, .day], from: alertDate)
        components.hour   = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelExDivAlert(for holding: Holding) {
        center.removePendingNotificationRequests(withIdentifiers: [exDivNotificationId(for: holding)])
    }

    private func exDivNotificationId(for holding: Holding) -> String {
        "exdiv-\(holding.id.uuidString)"
    }

    // MARK: - Dividend Received Alert

    /// Schedules a pay-date notification at 9:00 AM on the dividend's payDate.
    /// Uses the DividendEvent id as the notification identifier.
    func scheduleDividendReceivedAlert(for event: DividendEvent) {
        guard event.payDate > Date() else { return }

        cancelDividendReceivedAlert(for: event)

        let id = dividendReceivedNotificationId(for: event)
        let content = UNMutableNotificationContent()
        let amountStr = event.grossAmount.formatted(.currency(code: "USD"))
        content.title = "\(event.symbol) dividend received"
        if event.isReinvested {
            content.body = "\(amountStr) dividend reinvested (\(event.reinvestedShares.formatted()) shares added)."
        } else {
            content.body = "\(amountStr) dividend payment scheduled for today."
        }
        content.sound = .default

        var components = Calendar.current.dateComponents([.year, .month, .day], from: event.payDate)
        components.hour   = 9
        components.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }

    func cancelDividendReceivedAlert(for event: DividendEvent) {
        center.removePendingNotificationRequests(withIdentifiers: [dividendReceivedNotificationId(for: event)])
    }

    private func dividendReceivedNotificationId(for event: DividendEvent) -> String {
        "dividend-received-\(event.id.uuidString)"
    }

    // MARK: - Bulk Reschedule

    /// Reschedules ex-div alerts for all holdings with a future ex-dividend date.
    func rescheduleAll(holdings: [Holding]) {
        for holding in holdings where !(holding.assetType == .options || holding.assetType == .treasury) {
            scheduleExDivAlert(for: holding)
        }
    }
}
