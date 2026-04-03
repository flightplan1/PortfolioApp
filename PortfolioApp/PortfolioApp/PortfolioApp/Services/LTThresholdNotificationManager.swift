import Foundation
import UserNotifications

// MARK: - LTThresholdNotificationManager
// Schedules a local notification 1 day before each open lot qualifies for long-term
// capital gains treatment (366-day rule). Runs on every app foreground; skips lots
// that already have a pending notification (idempotent by lot ID).

@MainActor
final class LTThresholdNotificationManager {

    static let shared = LTThresholdNotificationManager()
    private init() {}

    private let center = UNUserNotificationCenter.current()
    private let idPrefix = "lt_threshold_"

    // MARK: - Public API

    /// Schedules LT-threshold notifications for all qualifying open lots.
    /// Builds a holdingId→symbol map from the provided holdings array.
    func scheduleAll(lots: [Lot], holdings: [Holding], prefs: NotificationPreferencesManager) async {
        guard prefs.ltThresholdAlertsEnabled else {
            await cancelAll()
            return
        }

        let symbolMap: [UUID: String] = Dictionary(
            uniqueKeysWithValues: holdings.map { ($0.id, $0.symbol) }
        )

        let pending = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map { $0.identifier })

        for lot in lots where !lot.isClosed && !lot.isSoftDeleted {
            guard let ltDate = lot.longTermQualifyingDate, ltDate > Date() else { continue }

            let symbol = symbolMap[lot.holdingId] ?? "position"
            guard !prefs.isMuted(symbol) else { continue }

            let notifId = "\(idPrefix)\(lot.id.uuidString)"
            guard !pendingIds.contains(notifId) else { continue }   // already scheduled

            // Fire day before at 9 AM
            guard let dayBefore = Calendar.current.date(byAdding: .day, value: -1, to: ltDate),
                  dayBefore > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Long-Term Tax Rate Tomorrow: \(symbol)"
            content.body  = "Your \(symbol) lot qualifies for the lower long-term rate tomorrow — hold to save on taxes."
            content.sound = .default
            content.userInfo = ["lotId": lot.id.uuidString, "symbol": symbol, "type": "lt_threshold"]

            var comps = Calendar.current.dateComponents([.year, .month, .day], from: dayBefore)
            comps.hour   = 9
            comps.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request  = UNNotificationRequest(identifier: notifId, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    /// Cancels all pending LT threshold notifications.
    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(idPrefix) }
            .map { $0.identifier }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Cancels LT notification for a single lot (call when lot is sold or closed).
    func cancel(lotId: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: ["\(idPrefix)\(lotId.uuidString)"]
        )
    }
}
