import Foundation

// MARK: - Models

struct IndustrySector: Codable, Identifiable {
    let key:        String
    let name:       String
    let color:      String
    let industries: [String]

    var id: String { key }
}

struct IndustryGraph: Codable {
    let version:   String
    let updatedAt: String
    let sectors:   [IndustrySector]
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

    /// Returns the sector that contains `industry`, or nil if not found.
    static func sector(for industry: String) -> IndustrySector? {
        load().sectors.first { $0.industries.contains(industry) }
    }

    /// Returns all sector names sorted by their order in the JSON.
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
}
