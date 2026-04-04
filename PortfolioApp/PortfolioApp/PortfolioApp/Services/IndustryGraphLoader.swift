import Foundation

// MARK: - Models

struct IndustrySector: Codable, Identifiable {
    let key:        String
    let name:       String
    let color:      String
    let industries: [String]

    var id: String { key }
}

/// Per-symbol supply chain node.
/// Static entries (from industry-graph.json): upstream/downstream populated, peers empty.
/// Dynamic entries (from user-graph.json via Finnhub): upstream/downstream empty, peers populated.
struct CompanyNode: Identifiable {
    let symbol:     String
    let name:       String
    let sector:     String      // matches IndustrySector.key; empty for Finnhub-sourced entries
    let industry:   String
    let upstream:   [String]
    let downstream: [String]
    let peers:      [String]    // Finnhub peer group; empty for static entries
    let isDynamic:  Bool        // true = came from user-graph.json (Finnhub)

    var id: String { symbol }
}

struct IndustryGraph: Codable {
    let version:   String
    let updatedAt: String
    let sectors:   [IndustrySector]
    let companies: [String: CompanyNodeRaw]

    func companyNode(for symbol: String) -> CompanyNode? {
        guard let raw = companies[symbol.uppercased()] else { return nil }
        return CompanyNode(
            symbol:     symbol.uppercased(),
            name:       raw.name,
            sector:     raw.sector,
            industry:   raw.industry,
            upstream:   raw.upstream,
            downstream: raw.downstream,
            peers:      raw.peers ?? [],
            isDynamic:  false
        )
    }

    func allCompanyNodes() -> [CompanyNode] {
        companies.map { key, raw in
            CompanyNode(symbol: key.uppercased(), name: raw.name, sector: raw.sector,
                        industry: raw.industry, upstream: raw.upstream, downstream: raw.downstream,
                        peers: raw.peers ?? [], isDynamic: false)
        }.sorted { $0.symbol < $1.symbol }
    }
}

/// Intermediate decodable — symbol comes from the dictionary key, not from the JSON value.
/// Used for both the static bundle graph and the dynamic user graph in Documents.
struct CompanyNodeRaw: Codable {
    let name:       String
    let sector:     String
    let industry:   String
    let upstream:   [String]
    let downstream: [String]
    let peers:      [String]?   // optional — only present in Finnhub-sourced entries
}

// MARK: - IndustryGraphLoader

enum IndustryGraphLoader {

    // MARK: - Caches

    private static var _staticCached: IndustryGraph?
    private static var _userCached: [String: CompanyNodeRaw]?

    private static var userGraphURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("user-graph.json")
    }

    // MARK: - Load

    static func load() -> IndustryGraph {
        if let cached = _staticCached { return cached }
        guard let url = Bundle.main.url(forResource: "industry-graph", withExtension: "json") else {
            fatalError("industry-graph.json missing from bundle")
        }
        do {
            let data  = try Data(contentsOf: url)
            let graph = try JSONDecoder().decode(IndustryGraph.self, from: data)
            _staticCached = graph
            return graph
        } catch {
            fatalError("Failed to decode industry-graph.json: \(error)")
        }
    }

    private static func loadUserGraph() -> [String: CompanyNodeRaw] {
        if let cached = _userCached { return cached }
        guard let data = try? Data(contentsOf: userGraphURL),
              let dict = try? JSONDecoder().decode([String: CompanyNodeRaw].self, from: data) else {
            _userCached = [:]
            return [:]
        }
        _userCached = dict
        return dict
    }

    /// Called by DynamicGraphService after every write to force a fresh read next access.
    static func invalidateUserGraphCache() {
        _userCached = nil
    }

    // MARK: - Sector Helpers

    static func sector(for industry: String) -> IndustrySector? {
        load().sectors.first { $0.industries.contains(industry) }
    }

    static func allSectors() -> [IndustrySector] { load().sectors }

    static func allIndustries() -> [String] {
        load().sectors.flatMap(\.industries).sorted()
    }

    static func industries(for sectorKey: String) -> [String] {
        load().sectors.first { $0.key == sectorKey }?.industries ?? []
    }

    // MARK: - Company Helpers

    /// Returns a CompanyNode for the symbol — checks static graph first, then user graph.
    static func company(for symbol: String) -> CompanyNode? {
        let key = symbol.uppercased()
        if let node = load().companyNode(for: key) { return node }
        let userGraph = loadUserGraph()
        guard let raw = userGraph[key] else { return nil }
        return CompanyNode(
            symbol:     key,
            name:       raw.name,
            sector:     raw.sector,
            industry:   raw.industry,
            upstream:   raw.upstream,
            downstream: raw.downstream,
            peers:      raw.peers ?? [],
            isDynamic:  true
        )
    }

    static func allCompanies() -> [CompanyNode] {
        var nodes = load().allCompanyNodes()
        let staticKeys = Set(nodes.map { $0.symbol })
        for (key, raw) in loadUserGraph() where !staticKeys.contains(key.uppercased()) {
            nodes.append(CompanyNode(symbol: key.uppercased(), name: raw.name, sector: raw.sector,
                                     industry: raw.industry, upstream: raw.upstream,
                                     downstream: raw.downstream, peers: raw.peers ?? [], isDynamic: true))
        }
        return nodes.sorted { $0.symbol < $1.symbol }
    }

    static func upstreamNodes(for symbol: String) -> [CompanyNode] {
        guard let node = company(for: symbol) else { return [] }
        return node.upstream.compactMap { company(for: $0) }
    }

    static func downstreamNodes(for symbol: String) -> [CompanyNode] {
        guard let node = company(for: symbol) else { return [] }
        return node.downstream.compactMap { company(for: $0) }
    }

    static func sectorColor(for key: String) -> String {
        load().sectors.first { $0.key == key }?.color ?? "#888888"
    }
}
