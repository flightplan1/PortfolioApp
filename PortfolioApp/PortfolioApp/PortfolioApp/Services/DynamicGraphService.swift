import Foundation
import Combine

// MARK: - Dynamic Graph Service

/// Maintains a persisted `user-graph.json` in Documents for holdings not in the static graph.
/// Fetches company name, industry, and peers from Finnhub and stores them as CompanyNodeRaw
/// entries — the same format IndustryGraphLoader reads for the static graph.
/// On every write, invalidates IndustryGraphLoader's user-graph cache so the next lookup
/// reflects the latest data.

@MainActor
final class DynamicGraphService: ObservableObject {

    static let shared = DynamicGraphService()

    @Published private(set) var isSyncing: Bool = false

    // In-memory mirror of user-graph.json
    private var entries: [String: CompanyNodeRaw] = [:]

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("user-graph.json")
    }()

    private init() {
        loadFromDisk()
    }

    // MARK: - Sync

    /// Syncs dynamic entries with the current stock/ETF holdings.
    /// Fetches missing symbols, removes entries for symbols no longer held.
    func syncWithHoldings(symbols: [String]) async {
        let keys = symbols.map { $0.uppercased() }
            .filter { IndustryGraphLoader.company(for: $0) == nil }  // skip static entries

        // Remove entries for symbols no longer held
        let heldSet = Set(keys)
        let staleKeys = Set(entries.keys).subtracting(heldSet)
        for key in staleKeys { entries.removeValue(forKey: key) }

        let toFetch = keys.filter { entries[$0] == nil }
        guard !toFetch.isEmpty || !staleKeys.isEmpty else { return }

        if !staleKeys.isEmpty { commit() }

        guard !toFetch.isEmpty else { return }
        isSyncing = true
        for symbol in toFetch {
            await fetchAndStore(symbol: symbol)
        }
        isSyncing = false
    }

    /// Fetches and stores a single symbol. Safe to call repeatedly — no-op if already cached.
    @discardableResult
    func fetchAndStore(symbol: String) async -> Bool {
        let key = symbol.uppercased()
        // Already covered by static graph or already fetched
        if IndustryGraphLoader.company(for: key) != nil { return true }
        if entries[key] != nil { return true }

        async let profileResult = StockProfileService.shared.profile(for: key)
        async let peersResult   = StockProfileService.shared.peers(for: key)
        let (profile, peers) = await (profileResult, peersResult)

        guard let profile else { return false }
        entries[key] = CompanyNodeRaw(
            name:       profile.name,
            sector:     "",             // Finnhub free tier has no sector key mapping
            industry:   profile.industry,
            upstream:   [],
            downstream: [],
            peers:      peers
        )
        commit()
        return true
    }

    /// Removes the entry for a symbol (call when a holding is deleted).
    func remove(symbol: String) {
        let removed = entries.removeValue(forKey: symbol.uppercased())
        if removed != nil { commit() }
    }

    // MARK: - Persistence

    private func commit() {
        saveToDisk()
        IndustryGraphLoader.invalidateUserGraphCache()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: CompanyNodeRaw].self, from: data) else { return }
        entries = dict
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
