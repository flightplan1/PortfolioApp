import Foundation

// MARK: - Stock Profile

struct StockProfile {
    let symbol: String
    let name: String
    let sector: String      // e.g. "Technology"
    let industry: String    // e.g. "Semiconductors"
    let country: String
    let exchange: String
    let logoURL: String?
}

// MARK: - Finnhub Decodables

private struct FinnhubProfile: Decodable {
    let name: String?
    let finnhubIndustry: String?
    let exchange: String?
    let country: String?
    let logo: String?
}

// MARK: - Stock Profile Service

/// Fetches sector, industry, and peer data from Finnhub for symbols not in the local industry graph.
/// All results are cached in memory for the app session — no re-fetches for the same symbol.
@MainActor
final class StockProfileService {

    static let shared = StockProfileService()

    // MARK: - Cache

    private var profileCache: [String: StockProfile] = [:]
    private var peersCache: [String: [String]] = [:]

    // In-flight tasks to avoid duplicate requests for the same symbol
    private var profileTasks: [String: Task<StockProfile?, Never>] = [:]
    private var peersTasks: [String: Task<[String], Never>] = [:]

    private init() {}

    // MARK: - Public API

    func profile(for symbol: String) async -> StockProfile? {
        let key = symbol.uppercased()

        if let cached = profileCache[key] { return cached }

        // Re-use in-flight task if one is already running
        if let existing = profileTasks[key] {
            return await existing.value
        }

        let task = Task<StockProfile?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await self.fetchProfile(symbol: key)
            self.profileTasks.removeValue(forKey: key)
            if let result { self.profileCache[key] = result }
            return result
        }
        profileTasks[key] = task
        return await task.value
    }

    func peers(for symbol: String) async -> [String] {
        let key = symbol.uppercased()

        if let cached = peersCache[key] { return cached }

        if let existing = peersTasks[key] {
            return await existing.value
        }

        let task = Task<[String], Never> { [weak self] in
            guard let self else { return [] }
            let result = await self.fetchPeers(symbol: key)
            self.peersTasks.removeValue(forKey: key)
            self.peersCache[key] = result
            return result
        }
        peersTasks[key] = task
        return await task.value
    }

    // MARK: - Fetch: Profile

    private func fetchProfile(symbol: String) async -> StockProfile? {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return nil }

        var comps = URLComponents(string: "https://finnhub.io/api/v1/stock/profile2")!
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let raw = try JSONDecoder().decode(FinnhubProfile.self, from: data)
            guard let name = raw.name, !name.isEmpty else { return nil }

            // Finnhub returns a single "finnhubIndustry" field — use it for both
            let industry = raw.finnhubIndustry ?? ""
            return StockProfile(
                symbol: symbol,
                name: name,
                sector: industry,       // best we have from free tier
                industry: industry,
                country: raw.country ?? "",
                exchange: raw.exchange ?? "",
                logoURL: raw.logo
            )
        } catch {
            return nil
        }
    }

    // MARK: - Fetch: Peers

    private func fetchPeers(symbol: String) async -> [String] {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return [] }

        var comps = URLComponents(string: "https://finnhub.io/api/v1/stock/peers")!
        comps.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let peers = try JSONDecoder().decode([String].self, from: data)
            // Exclude the symbol itself from the peer list
            return peers.filter { $0.uppercased() != symbol.uppercased() }
        } catch {
            return []
        }
    }
}
