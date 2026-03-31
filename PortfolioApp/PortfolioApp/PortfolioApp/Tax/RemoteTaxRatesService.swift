import Foundation
import Combine

// MARK: - Rates Source

enum RatesSource: Equatable {
    case bundled
    case cached(version: String)
    case remote(version: String)

    var label: String {
        switch self {
        case .bundled:          return "Bundled (offline)"
        case .cached(let v):    return "Cached · v\(v)"
        case .remote(let v):    return "Remote · v\(v)"
        }
    }

    var isOffline: Bool {
        if case .bundled = self { return true }
        return false
    }
}

// MARK: - RemoteTaxRatesService

@MainActor
final class RemoteTaxRatesService: ObservableObject {

    static let shared = RemoteTaxRatesService()

    // MARK: - Persistence keys
    private let kvStore      = NSUbiquitousKeyValueStore.default
    private let urlKey       = "com.portfolioapp.taxRatesRemoteURL"
    private let lastFetchKey = "com.portfolioapp.taxRatesLastFetch"
    private let cacheFilename = "tax-rates-remote.json"

    // MARK: - Published state
    @Published var activeRates:    TaxRates
    @Published var ratesSource:    RatesSource = .bundled
    @Published var isOutdated:     Bool = false
    @Published var isFetching:     Bool = false
    @Published var lastFetchDate:  Date?
    @Published var lastFetchError: String?
    @Published var remoteURL:      String = ""

    private init() {
        // Baseline: bundled rates
        let bundled = TaxRatesLoader.loadBundled()
        activeRates = bundled
        ratesSource = .bundled

        remoteURL = kvStore.string(forKey: urlKey) ?? ""
        lastFetchDate = UserDefaults.standard.object(forKey: lastFetchKey) as? Date

        // Promote to cached if available and newer
        if let cached = loadCachedRates(), isNewer(cached.version, than: bundled.version) {
            activeRates = cached
            ratesSource = .cached(version: cached.version)
        }

        updateOutdatedFlag()
        TaxRatesLoader.setActive(activeRates)
    }

    // MARK: - Remote URL management

    func saveRemoteURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteURL = trimmed
        if trimmed.isEmpty {
            kvStore.removeObject(forKey: urlKey)
        } else {
            kvStore.set(trimmed, forKey: urlKey)
        }
        kvStore.synchronize()
    }

    // MARK: - Fetch control

    /// Fetches only if the remote URL is set and 30+ days have passed since the last fetch.
    func fetchIfNeeded() async {
        guard shouldFetch else { return }
        await fetch()
    }

    var shouldFetch: Bool {
        guard !remoteURL.isEmpty else { return false }
        guard let last = lastFetchDate else { return true }
        return Date().timeIntervalSince(last) > 30 * 24 * 60 * 60
    }

    /// Forces an immediate fetch regardless of schedule.
    func fetch() async {
        guard !remoteURL.isEmpty, let url = URL(string: remoteURL) else {
            lastFetchError = "No valid remote URL configured."
            return
        }

        isFetching = true
        lastFetchError = nil

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }

            let fetched = try JSONDecoder().decode(TaxRates.self, from: data)

            // Only promote if fetched version is strictly newer than current
            if isNewer(fetched.version, than: activeRates.version) {
                activeRates = fetched
                ratesSource = .remote(version: fetched.version)
                TaxRatesLoader.setActive(fetched)
                saveCachedRates(data)
            }

            lastFetchDate = Date()
            UserDefaults.standard.set(lastFetchDate, forKey: lastFetchKey)
            updateOutdatedFlag()

        } catch {
            lastFetchError = error.localizedDescription
        }

        isFetching = false
    }

    // MARK: - Outdated detection

    private func updateOutdatedFlag() {
        let currentYear = Calendar.current.component(.year, from: Date())
        isOutdated = activeRates.effectiveYear < currentYear
    }

    // MARK: - Version comparison ("2026.1" format)

    /// Returns true when `a` is strictly newer than `b`.
    private func isNewer(_ a: String, than b: String) -> Bool {
        let av = parseVersion(a)
        let bv = parseVersion(b)
        if av.year != bv.year { return av.year > bv.year }
        return av.revision > bv.revision
    }

    private func parseVersion(_ v: String) -> (year: Int, revision: Int) {
        let parts = v.split(separator: ".").map { Int($0) ?? 0 }
        return (year: parts.first ?? 0, revision: parts.dropFirst().first ?? 0)
    }

    // MARK: - Disk cache

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(cacheFilename)
    }

    private func saveCachedRates(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadCachedRates() -> TaxRates? {
        guard let url = cacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaxRates.self, from: data)
    }
}
