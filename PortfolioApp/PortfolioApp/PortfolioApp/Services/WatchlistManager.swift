import Foundation
import Combine

// MARK: - Watchlist Manager

/// Manages the user's watchlist — symbols tracked for price/news without being held.
/// Persisted to NSUbiquitousKeyValueStore so it syncs across devices via iCloud.

@MainActor
final class WatchlistManager: ObservableObject {

    static let shared = WatchlistManager()

    @Published private(set) var symbols: [String] = []

    private let kvKey = "watchlist_symbols_v1"
    private let store = NSUbiquitousKeyValueStore.default

    private init() {
        load()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()
    }

    // MARK: - Public API

    func add(_ symbol: String) {
        let key = symbol.uppercased()
        guard !symbols.contains(key) else { return }
        symbols.append(key)
        save()
    }

    func remove(_ symbol: String) {
        symbols.removeAll { $0 == symbol.uppercased() }
        save()
    }

    func contains(_ symbol: String) -> Bool {
        symbols.contains(symbol.uppercased())
    }

    // MARK: - Persistence

    private func load() {
        symbols = (store.array(forKey: kvKey) as? [String]) ?? []
    }

    private func save() {
        store.set(symbols, forKey: kvKey)
        store.synchronize()
    }

    @objc private func storeDidChange(_ notification: Notification) {
        load()
    }
}
