import Foundation
import Combine
import CoreData
import UserNotifications

// MARK: - PriceAlertService
// Observes PriceService.$prices on every refresh.
// For each untriggered PriceAlert whose condition is now met:
//   - fires a local UNUserNotificationCenter notification
//   - marks the alert as triggered + records triggeredAt

final class PriceAlertService {

    static let shared = PriceAlertService()
    private init() {}

    private var cancellable: AnyCancellable?
    private var context: NSManagedObjectContext?

    // MARK: - Start

    /// Call once on app launch (or on each foreground — safe to call repeatedly).
    func start(priceService: PriceService, context: NSManagedObjectContext) {
        self.context = context
        guard cancellable == nil else { return }   // already subscribed
        cancellable = priceService.$prices
            .dropFirst()                        // skip initial empty value
            .sink { [weak self] prices in
                self?.checkAlerts(prices: prices)
            }
    }

    // MARK: - Check

    private func checkAlerts(prices: [String: PriceData]) {
        guard let context else { return }
        let alerts = (try? context.fetch(PriceAlert.allUntriggered())) ?? []
        guard !alerts.isEmpty else { return }

        var triggered: [PriceAlert] = []

        for alert in alerts {
            guard let priceData = prices[alert.symbol] else { continue }
            if alert.isConditionMet(currentPrice: priceData.currentPrice) {
                alert.isTriggered = true
                alert.triggeredAt = Date()
                triggered.append(alert)
            }
        }

        guard !triggered.isEmpty else { return }
        try? context.save()

        for alert in triggered {
            fireNotification(for: alert)
        }
    }

    // MARK: - Notification

    private func fireNotification(for alert: PriceAlert) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.symbol) Price Alert"
        let dirLabel = alert.direction == .above ? "reached" : "dropped to"
        content.body = "\(alert.symbol) has \(dirLabel) \(alert.targetPrice.asCurrency)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "price-alert-\(alert.id)",
            content: content,
            trigger: nil   // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Permission

    /// Request notification permission if not yet determined.
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                ) { _, _ in }
            }
        }
    }
}
