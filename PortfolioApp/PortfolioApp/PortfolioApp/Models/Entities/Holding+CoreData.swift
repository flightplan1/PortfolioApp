import Foundation
import CoreData

// MARK: - Holding
// Represents a single position (stock, ETF, crypto, options, or treasury).
// Parent entity in CoreData: BaseFinancialRecord

@objc(Holding)
public class Holding: BaseFinancialRecord, Identifiable {

    // MARK: - Core Identity

    @NSManaged public var id: UUID
    @NSManaged public var symbol: String
    @NSManaged public var name: String
    @NSManaged public var assetTypeRaw: String        // Maps to AssetType enum
    @NSManaged public var sector: String?
    @NSManaged public var currency: String            // Default: "USD"
    @NSManaged public var notes: String?
    @NSManaged public var createdAt: Date

    // MARK: - Dividend

    @NSManaged public var isDRIPEnabled: Bool
    @NSManaged public var dividendFrequencyRaw: String? // Maps to DividendFrequency enum
    @NSManaged public var lastDividendPerShareRaw: NSDecimalNumber?
    @NSManaged public var lastExDividendDate: Date?

    // MARK: - Options-Specific

    @NSManaged public var strikePriceRaw: NSDecimalNumber?
    @NSManaged public var underlyingPriceAtExecutionRaw: NSDecimalNumber?
    @NSManaged public var expiryDate: Date?
    @NSManaged public var optionTypeRaw: String?        // Maps to OptionType enum
    @NSManaged public var isSection1256: Bool
    /// True when the option position was opened short (sell-to-open / write).
    /// Flips the P&L sign: profit when option declines, loss when it rises.
    @NSManaged public var isShortPosition: Bool
    @NSManaged public var bankFeeRaw: NSDecimalNumber?
    @NSManaged public var underlyingSymbol: String?

    // MARK: - Relationships (defined in model editor)
    // lots: Set<Lot>
    // transactions: Set<Transaction>

    // MARK: - Lifecycle

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
        currency = "USD"
        isDRIPEnabled = false
        isSection1256 = false
        isShortPosition = false
        assetTypeRaw = AssetType.stock.rawValue
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension Holding {
    var lastDividendPerShare: Decimal? {
        get { lastDividendPerShareRaw?.decimalValue }
        set { lastDividendPerShareRaw = newValue.map { $0 as NSDecimalNumber } }
    }

    var strikePrice: Decimal? {
        get { strikePriceRaw?.decimalValue }
        set { strikePriceRaw = newValue.map { $0 as NSDecimalNumber } }
    }

    var underlyingPriceAtExecution: Decimal? {
        get { underlyingPriceAtExecutionRaw?.decimalValue }
        set { underlyingPriceAtExecutionRaw = newValue.map { $0 as NSDecimalNumber } }
    }

    var bankFee: Decimal? {
        get { bankFeeRaw?.decimalValue }
        set { bankFeeRaw = newValue.map { $0 as NSDecimalNumber } }
    }
}

// MARK: - Enum Wrappers

extension Holding {
    var assetType: AssetType {
        get { AssetType(rawValue: assetTypeRaw) ?? .stock }
        set { assetTypeRaw = newValue.rawValue; markModified() }
    }

    var dividendFrequency: DividendFrequency? {
        get { dividendFrequencyRaw.flatMap(DividendFrequency.init) }
        set { dividendFrequencyRaw = newValue?.rawValue; markModified() }
    }

    var optionType: OptionType? {
        get { optionTypeRaw.flatMap(OptionType.init) }
        set { optionTypeRaw = newValue?.rawValue; markModified() }
    }
}

// MARK: - Computed Properties

extension Holding {
    var isOption: Bool { assetType == .options }
    var isCrypto: Bool { assetType == .crypto }

    /// The ×100 multiplier applied to options lots (1 contract = 100 shares).
    /// Use this when computing market value, cost basis, or P&L from lot quantities.
    var lotMultiplier: Decimal { isOption ? 100 : 1 }

    /// +1 for long positions (and all non-option holdings), -1 for short (sell-to-open) options.
    /// Multiply unrealized P&L by this to get the correctly signed value.
    var pnlDirection: Decimal { (isOption && isShortPosition) ? -1 : 1 }
    var isTreasury: Bool { assetType == .treasury }
    var isETF: Bool { assetType == .etf }
    var isStock: Bool { assetType == .stock }

    var isOptionExpired: Bool {
        guard isOption, let expiry = expiryDate else { return false }
        return expiry < Date()
    }

    var daysUntilExpiry: Int? {
        guard isOption, let expiry = expiryDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        return days >= 0 ? days : nil
    }

    var priceSource: PriceSource { assetType.priceSource }

    /// For display in the Holdings list chip
    var typeDisplayName: String { assetType.displayName }

    /// For display in the Holdings list chip
    var typeChipColor: AppChipColor { assetType.chipColor }
}

// MARK: - Fetch Requests

extension Holding {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Holding> {
        NSFetchRequest<Holding>(entityName: "Holding")
    }

    static func allActiveRequest() -> NSFetchRequest<Holding> {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Holding.symbol, ascending: true)]
        return request
    }

    static func byAssetType(_ type: AssetType) -> NSFetchRequest<Holding> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "assetTypeRaw == %@", type.rawValue)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Holding.symbol, ascending: true)]
        return request
    }
}

// MARK: - Enums

enum AssetType: String, CaseIterable, Codable {
    case stock    = "stock"
    case etf      = "etf"
    case crypto   = "crypto"
    case options  = "options"
    case treasury = "treasury"
    case cash     = "cash"

    var displayName: String {
        switch self {
        case .stock:    return "STOCK"
        case .etf:      return "ETF"
        case .crypto:   return "CRYPTO"
        case .options:  return "OPTION"
        case .treasury: return "T-BILL"
        case .cash:     return "CASH"
        }
    }

    var fullName: String {
        switch self {
        case .stock:    return "Stock"
        case .etf:      return "ETF"
        case .crypto:   return "Crypto"
        case .options:  return "Options"
        case .treasury: return "Treasury"
        case .cash:     return "Cash"
        }
    }

    var pluralName: String {
        switch self {
        case .stock:    return "Stocks"
        case .etf:      return "ETFs"
        case .crypto:   return "Crypto"
        case .options:  return "Options"
        case .treasury: return "T-Bills"
        case .cash:     return "Cash"
        }
    }

    var chipColor: AppChipColor {
        switch self {
        case .stock:    return .blue
        case .etf:      return .teal
        case .crypto:   return .gold
        case .options:  return .purple
        case .treasury: return .slate
        case .cash:     return .green
        }
    }

    var priceSource: PriceSource {
        switch self {
        case .stock, .etf, .options, .treasury: return .finnhub
        case .crypto:                           return .coingecko
        case .cash:                             return .manual
        }
    }
}

enum DividendFrequency: String, CaseIterable, Codable {
    case monthly     = "monthly"
    case quarterly   = "quarterly"
    case semiAnnual  = "semiAnnual"
    case annual      = "annual"
    case irregular   = "irregular"

    var displayName: String {
        switch self {
        case .monthly:    return "Monthly"
        case .quarterly:  return "Quarterly"
        case .semiAnnual: return "Semi-Annual"
        case .annual:     return "Annual"
        case .irregular:  return "Irregular"
        }
    }
}

enum OptionType: String, CaseIterable, Codable {
    case call = "call"
    case put  = "put"

    var displayName: String { rawValue.capitalized }
}

enum AppChipColor {
    case blue, teal, gold, purple, green, slate
}
