import Foundation
import WidgetKit

/// Writes a lightweight portfolio snapshot to the shared App Group UserDefaults
/// so the PortfolioWidget extension can display live data without CoreData access.
///
/// Call `WidgetDataWriter.write(totalValue:todayChange:todayChangePct:)` whenever
/// portfolio values change (on price refresh or app foreground).
struct WidgetDataWriter {

    private static let appGroupID = "group.com.yourname.PortfolioApp"
    private static let snapshotKey = "widget_portfolio_snapshot_v1"

    static func write(totalValue: Decimal, todayChange: Decimal, todayChangePct: Decimal) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let snapshot = WidgetSnapshot(
            totalValue: (totalValue as NSDecimalNumber).doubleValue,
            todayChange: (todayChange as NSDecimalNumber).doubleValue,
            todayChangePct: (todayChangePct as NSDecimalNumber).doubleValue,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "PortfolioWidget")
    }

    // MARK: - Private Model

    private struct WidgetSnapshot: Codable {
        let totalValue: Double
        let todayChange: Double
        let todayChangePct: Double
        let updatedAt: Date
    }
}
