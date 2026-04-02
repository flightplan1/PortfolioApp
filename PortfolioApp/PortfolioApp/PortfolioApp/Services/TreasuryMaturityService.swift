import Foundation
import CoreData
import UserNotifications

// MARK: - TreasuryMaturityService
// Checks for matured positions on app launch, schedules maturity alerts,
// and fires I-Bond rate update reminders every May and November.

final class TreasuryMaturityService {

    static let shared = TreasuryMaturityService()
    private init() {}

    // MARK: - Start

    func start(context: NSManagedObjectContext) {
        checkMaturedPositions(context: context)
        scheduleIBondRateReminders()
    }

    // MARK: - Check Matured Positions

    private func checkMaturedPositions(context: NSManagedObjectContext) {
        let positions = (try? context.fetch(TreasuryPosition.allUnmatured())) ?? []
        let now = Date()
        var changed = false

        for pos in positions where pos.maturityDate <= now && !pos.isMatured {
            // Fire notification for positions that matured since last launch
            fireMaturityNotification(for: pos)
            changed = true
        }

        if changed {
            try? context.save()
        }
    }

    // MARK: - Schedule Maturity Alert

    func scheduleMaturityAlert(for position: TreasuryPosition, symbol: String) {
        guard !position.maturityAlertScheduled, !position.isMatured else { return }
        let center = UNUserNotificationCenter.current()

        // 30-day warning
        if let date30 = Calendar.current.date(byAdding: .day, value: -30, to: position.maturityDate),
           date30 > Date() {
            scheduleNotification(
                id: "treasury-30d-\(position.id)",
                title: "\(symbol) Matures in 30 Days",
                body: "Your treasury position matures on \(position.maturityDate.formatted(.dateTime.month(.abbreviated).day().year())). Face value: \(position.faceValue.asCurrency).",
                date: date30,
                center: center
            )
        }

        // 7-day warning
        if let date7 = Calendar.current.date(byAdding: .day, value: -7, to: position.maturityDate),
           date7 > Date() {
            scheduleNotification(
                id: "treasury-7d-\(position.id)",
                title: "\(symbol) Matures in 7 Days",
                body: "Your treasury position matures on \(position.maturityDate.formatted(.dateTime.month(.abbreviated).day().year())).",
                date: date7,
                center: center
            )
        }

        // Day-of
        if position.maturityDate > Date() {
            scheduleNotification(
                id: "treasury-due-\(position.id)",
                title: "\(symbol) Has Matured",
                body: "Your treasury matures today. Open the app to record the maturity and credit proceeds to cash.",
                date: position.maturityDate,
                center: center
            )
        }

        position.maturityAlertScheduled = true
        try? position.managedObjectContext?.save()
    }

    // MARK: - I-Bond Rate Update Reminders
    // Fires around May 1 and November 1 each year to remind users to check new rates.

    private func scheduleIBondRateReminders() {
        let center = UNUserNotificationCenter.current()
        let cal    = Calendar.current
        let now    = Date()
        let year   = cal.component(.year, from: now)

        for yr in [year, year + 1] {
            for (month, label) in [(5, "May"), (11, "November")] {
                guard let date = cal.date(from: DateComponents(year: yr, month: month, day: 1)),
                      date > now else { continue }
                scheduleNotification(
                    id: "ibond-rate-\(yr)-\(month)",
                    title: "I-Bond Rate Update",
                    body: "The Treasury has announced new I-Bond rates for \(label) \(yr). Open PortfolioApp to update your composite rates.",
                    date: date,
                    center: center
                )
            }
        }
    }

    // MARK: - Fire Immediate Maturity Notification

    private func fireMaturityNotification(for position: TreasuryPosition) {
        let content = UNMutableNotificationContent()
        content.title = "Treasury Position Matured"
        content.body  = "Your \(position.faceValue.asCurrency) position (CUSIP: \(position.cusip ?? "–")) has matured. Open PortfolioApp to record proceeds."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "treasury-matured-\(position.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helper: Schedule Dated Notification

    private func scheduleNotification(
        id: String,
        title: String,
        body: String,
        date: Date,
        center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
