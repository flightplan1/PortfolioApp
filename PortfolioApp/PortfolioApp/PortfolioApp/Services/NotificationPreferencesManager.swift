import Foundation
import Combine

// MARK: - NotificationPreferencesManager
// Stores per-type and per-symbol notification preferences in UserDefaults.
// Shared singleton; inject as @StateObject or reference .shared directly.

@MainActor
final class NotificationPreferencesManager: ObservableObject {

    static let shared = NotificationPreferencesManager()

    private enum Keys {
        static let earnings     = "notif_earnings_v1"
        static let ltThreshold  = "notif_lt_v1"
        static let breakingNews = "notif_breaking_v1"
        static let mutedSymbols = "notif_muted_symbols_v1"
    }

    // MARK: - Published Preferences

    @Published var earningsAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(earningsAlertsEnabled, forKey: Keys.earnings) }
    }

    @Published var ltThresholdAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(ltThresholdAlertsEnabled, forKey: Keys.ltThreshold) }
    }

    @Published var breakingNewsAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(breakingNewsAlertsEnabled, forKey: Keys.breakingNews) }
    }

    /// Symbols whose notifications are fully silenced (all types).
    @Published var mutedSymbols: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(mutedSymbols), forKey: Keys.mutedSymbols)
        }
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        earningsAlertsEnabled    = ud.object(forKey: Keys.earnings)     as? Bool ?? true
        ltThresholdAlertsEnabled = ud.object(forKey: Keys.ltThreshold)  as? Bool ?? true
        breakingNewsAlertsEnabled = ud.object(forKey: Keys.breakingNews) as? Bool ?? true
        let arr = ud.array(forKey: Keys.mutedSymbols) as? [String] ?? []
        mutedSymbols = Set(arr)
    }

    // MARK: - Helpers

    func isMuted(_ symbol: String) -> Bool { mutedSymbols.contains(symbol) }

    func toggleMute(_ symbol: String) {
        if mutedSymbols.contains(symbol) {
            mutedSymbols.remove(symbol)
        } else {
            mutedSymbols.insert(symbol)
        }
    }
}
