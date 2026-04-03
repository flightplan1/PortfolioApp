import Foundation

// MARK: - Models

struct IndustrySector: Codable, Identifiable {
    let key:        String
    let name:       String
    let color:      String
    let industries: [String]

    var id: String { key }
}

/// Per-symbol supply chain node. Upstream = suppliers; downstream = customers/dependents.
struct CompanyNode: Codable, Identifiable {
    let symbol:     String
    let name:       String
    let sector:     String      // matches IndustrySector.key
    let industry:   String
    let upstream:   [String]    // ticker symbols that supply to this company
    let downstream: [String]    // ticker symbols that depend on this company

    var id: String { symbol }
}

struct IndustryGraph: Codable {
    let version:   String
    let updatedAt: String
    let sectors:   [IndustrySector]
    let companies: [String: CompanyNodeRaw]

    // Decode companies as a flat dict, then hydrate with symbol key
    func companyNode(for symbol: String) -> CompanyNode? {
        guard let raw = companies[symbol] else { return nil }
        return CompanyNode(
            symbol:     symbol,
            name:       raw.name,
            sector:     raw.sector,
            industry:   raw.industry,
            upstream:   raw.upstream,
            downstream: raw.downstream
        )
    }

    func allCompanyNodes() -> [CompanyNode] {
        companies.map { key, raw in
            CompanyNode(symbol: key, name: raw.name, sector: raw.sector,
                        industry: raw.industry, upstream: raw.upstream, downstream: raw.downstream)
        }.sorted { $0.symbol < $1.symbol }
    }
}

/// Intermediate decodable — symbol comes from the dictionary key, not from the JSON value.
struct CompanyNodeRaw: Codable {
    let name:       String
    let sector:     String
    let industry:   String
    let upstream:   [String]
    let downstream: [String]
}

// MARK: - IndustryGraphLoader

enum IndustryGraphLoader {

    private static var _cached: IndustryGraph?

    static func load() -> IndustryGraph {
        if let cached = _cached { return cached }

        guard let url = Bundle.main.url(forResource: "industry-graph", withExtension: "json") else {
            fatalError("industry-graph.json missing from bundle")
        }
        do {
            let data  = try Data(contentsOf: url)
            let graph = try JSONDecoder().decode(IndustryGraph.self, from: data)
            _cached = graph
            return graph
        } catch {
            fatalError("Failed to decode industry-graph.json: \(error)")
        }
    }

    // MARK: - Sector Helpers

    /// Returns the sector that contains `industry`, or nil if not found.
    static func sector(for industry: String) -> IndustrySector? {
        load().sectors.first { $0.industries.contains(industry) }
    }

    /// Returns all sectors in JSON order.
    static func allSectors() -> [IndustrySector] {
        load().sectors
    }

    /// Returns all industry names across all sectors, sorted alphabetically.
    static func allIndustries() -> [String] {
        load().sectors.flatMap(\.industries).sorted()
    }

    /// Returns industries for a specific sector key.
    static func industries(for sectorKey: String) -> [String] {
        load().sectors.first { $0.key == sectorKey }?.industries ?? []
    }

    // MARK: - Company Helpers

    /// Returns the CompanyNode for a given ticker symbol, or nil if not in the graph.
    static func company(for symbol: String) -> CompanyNode? {
        load().companyNode(for: symbol)
    }

    /// Returns all companies in the graph sorted by symbol.
    static func allCompanies() -> [CompanyNode] {
        load().allCompanyNodes()
    }

    /// Returns companies that list `symbol` in their downstream array (i.e. direct customers).
    static func upstreamNodes(for symbol: String) -> [CompanyNode] {
        guard let node = company(for: symbol) else { return [] }
        return node.upstream.compactMap { company(for: $0) }
    }

    /// Returns companies that list `symbol` in their upstream array (i.e. direct dependents).
    static func downstreamNodes(for symbol: String) -> [CompanyNode] {
        guard let node = company(for: symbol) else { return [] }
        return node.downstream.compactMap { company(for: $0) }
    }

    /// Returns the sector color hex string for a given sector key.
    static func sectorColor(for key: String) -> String {
        load().sectors.first { $0.key == key }?.color ?? "#888888"
    }
}
