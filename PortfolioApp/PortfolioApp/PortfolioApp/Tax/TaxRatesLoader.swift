import Foundation

// MARK: - JSON-decodable tax rate structs

struct TaxBracket: Codable {
    let min: Decimal
    let max: Decimal?   // nil = no upper limit (top bracket)
    let rate: Decimal
}

struct FilingStatusBrackets: Codable {
    let single: [TaxBracket]
    let mfj:    [TaxBracket]
    let mfs:    [TaxBracket]
    let hoh:    [TaxBracket]

    func brackets(for status: FilingStatus) -> [TaxBracket] {
        switch status {
        case .single: return single
        case .mfj:    return mfj
        case .mfs:    return mfs
        case .hoh:    return hoh
        }
    }
}

struct NIITConfig: Codable {
    let rate: Decimal
    let thresholds: Thresholds

    struct Thresholds: Codable {
        let single: Decimal
        let mfj:    Decimal
        let mfs:    Decimal
        let hoh:    Decimal

        func threshold(for status: FilingStatus) -> Decimal {
            switch status {
            case .single: return single
            case .mfj:    return mfj
            case .mfs:    return mfs
            case .hoh:    return hoh
            }
        }
    }
}

struct FederalRates: Codable {
    let ordinary: FilingStatusBrackets
    let ltcg:     FilingStatusBrackets
    let niit:     NIITConfig
}

enum StateTaxType: String, Codable {
    case none         = "none"
    case flat         = "flat"
    case graduated    = "graduated"
    case capitalGains = "capitalgains"
}

struct StateRates: Codable {
    let name:                 String
    let type:                 StateTaxType
    let distinguishesLongTerm: Bool?
    let stTreatment:          String?   // "ordinary" | "special" | "none"
    let ltTreatment:          String?   // "ordinary" | "special" | "none"
    let rate:                 Decimal?  // flat rate
    let stRate:               Decimal?  // MA-style special ST rate
    let ltRate:               Decimal?  // MA-style special LT rate
    let ltcgRate:             Decimal?  // WA-style CG-only rate
    let ltcgThreshold:        Decimal?  // WA: gains above this threshold are taxed
    let brackets:             FilingStatusBrackets?
}

struct CityFilingBrackets: Codable {
    let single: [TaxBracket]?
    let mfj:    [TaxBracket]?

    func brackets(for status: FilingStatus) -> [TaxBracket]? {
        switch status {
        case .single, .mfs, .hoh: return single
        case .mfj:                return mfj
        }
    }
}

struct CityRates: Codable {
    let name:           String
    let state:          String
    let residentOnly:   Bool
    let nonResidentRate: Decimal?
    let appliesTo:      [String]   // ["shortTerm", "longTerm"]
    let type:           String     // "flat" | "graduated" | "surcharge"
    let rate:           Decimal?
    let surchargeRate:  Decimal?   // Yonkers: fraction of state tax owed
    let brackets:       CityFilingBrackets?
}

struct TaxRates: Codable {
    let version:       String
    let effectiveYear: Int
    let updatedAt:     String
    let federal:       FederalRates
    let states:        [String: StateRates]
    let cities:        [String: CityRates]
}

// MARK: - TaxRatesLoader

enum TaxRatesLoader {

    private static var _bundled: TaxRates?
    private static var _active:  TaxRates?

    // MARK: - Bundled (always from bundle — ignores remote override)

    /// Synchronously loads rates from the bundled tax-rates.json.
    /// Crashes loudly in DEBUG if the file is missing or malformed — not a recoverable runtime error.
    static func loadBundled() -> TaxRates {
        if let cached = _bundled { return cached }

        guard let url = Bundle.main.url(forResource: "tax-rates", withExtension: "json") else {
            fatalError("tax-rates.json missing from bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let rates = try JSONDecoder().decode(TaxRates.self, from: data)
            _bundled = rates
            return rates
        } catch {
            fatalError("Failed to decode tax-rates.json: \(error)")
        }
    }

    // MARK: - Active (remote/cached override when available)

    /// Returns the active rates — remote/cached if set via `setActive`, otherwise bundled.
    static func load() -> TaxRates {
        _active ?? loadBundled()
    }

    /// Called by RemoteTaxRatesService to promote a newer remote/cached version.
    static func setActive(_ rates: TaxRates) {
        _active = rates
    }

    /// Returns the display name for a state code, or nil if unknown.
    static func stateName(for code: String) -> String? {
        load().states[code]?.name
    }

    /// Returns all states sorted by name, excluding "none"-type states when `excludeNoTax` is true.
    static func allStates(excludeNoTax: Bool = false) -> [(code: String, name: String)] {
        load().states
            .filter { excludeNoTax ? $0.value.type != .none : true }
            .map    { (code: $0.key, name: $0.value.name) }
            .sorted { $0.name < $1.name }
    }

    /// Returns all states including no-tax states, sorted by name.
    static func allStatesIncludingNoTax() -> [(code: String, name: String)] {
        allStates(excludeNoTax: false)
    }

    /// Returns cities for a given state code, sorted by name.
    static func cities(for stateCode: String) -> [(key: String, name: String)] {
        load().cities
            .filter { $0.value.state == stateCode }
            .map    { (key: $0.key, name: $0.value.name) }
            .sorted { $0.name < $1.name }
    }
}
