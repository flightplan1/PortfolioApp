import WidgetKit
import SwiftUI

// MARK: - Shared App Group Key

/// The app group identifier must match what is configured in both targets'
/// Signing & Capabilities. See setup instructions in WIDGET_SETUP.md.
private let appGroupID = "group.com.yourname.PortfolioApp"
private let portfolioSnapshotKey = "widget_portfolio_snapshot_v1"

// MARK: - Snapshot Model

/// Lightweight snapshot written by the main app, read by the widget.
/// Stored in NSUserDefaults(suiteName: appGroupID).
struct PortfolioSnapshot: Codable {
    let totalValue: Double
    let todayChange: Double
    let todayChangePct: Double
    let updatedAt: Date

    static let placeholder = PortfolioSnapshot(
        totalValue: 124_563.00,
        todayChange: 812.45,
        todayChangePct: 0.66,
        updatedAt: Date()
    )
}

// MARK: - Timeline Entry

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let snapshot: PortfolioSnapshot
}

// MARK: - Timeline Provider

struct PortfolioProvider: TimelineProvider {

    func placeholder(in context: Context) -> PortfolioEntry {
        PortfolioEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        completion(PortfolioEntry(date: Date(), snapshot: loadSnapshot() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        let snapshot = loadSnapshot() ?? .placeholder
        let entry = PortfolioEntry(date: Date(), snapshot: snapshot)
        // Refresh every 15 minutes — widget data is written by the main app on foreground
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadSnapshot() -> PortfolioSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: portfolioSnapshotKey) else { return nil }
        return try? JSONDecoder().decode(PortfolioSnapshot.self, from: data)
    }
}

// MARK: - Widget View

struct PortfolioWidgetEntryView: View {
    let entry: PortfolioEntry

    private var isPositive: Bool { entry.snapshot.todayChange >= 0 }
    private var changeColor: Color { isPositive ? Color(red: 0.18, green: 0.80, blue: 0.44) : Color(red: 1.0, green: 0.35, blue: 0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Text("Portfolio")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(entry.snapshot.updatedAt, style: .time)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            // Total value
            Text(entry.snapshot.totalValue.formatted(.currency(code: "USD").presentation(.narrow)))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // Today change
            HStack(spacing: 4) {
                Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(entry.snapshot.todayChange.formatted(.currency(code: "USD").sign(strategy: .always())))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(String(format: "(%.2f%%)", abs(entry.snapshot.todayChangePct)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(changeColor.opacity(0.8))
            }
            .foregroundColor(changeColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let dir = isPositive ? "up" : "down"
        let value = entry.snapshot.totalValue.formatted(.currency(code: "USD").presentation(.narrow))
        let change = abs(entry.snapshot.todayChange).formatted(.currency(code: "USD").presentation(.narrow))
        let pct = String(format: "%.2f%%", abs(entry.snapshot.todayChangePct))
        return "Portfolio value \(value), \(dir) \(change) (\(pct)) today"
    }
}

// MARK: - Widget Configuration

@main
struct PortfolioWidget: Widget {
    let kind = "PortfolioWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioProvider()) { entry in
            PortfolioWidgetEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Portfolio")
        .description("Your total portfolio value and today's change.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

// MARK: - Medium Widget View (wider layout)

extension PortfolioWidgetEntryView {
    @ViewBuilder
    var mediumBody: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PORTFOLIO")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .kerning(0.5)
                Text(entry.snapshot.totalValue.formatted(.currency(code: "USD").presentation(.narrow)))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text(entry.snapshot.todayChange.formatted(.currency(code: "USD").sign(strategy: .always())))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(String(format: "(%.2f%%)", abs(entry.snapshot.todayChangePct)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(changeColor.opacity(0.8))
                }
                .foregroundColor(changeColor)
            }
            .padding(16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    }
}
