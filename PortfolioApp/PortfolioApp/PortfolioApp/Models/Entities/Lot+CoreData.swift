import Foundation
import CoreData

// MARK: - Lot
// A single tax lot within a Holding. Tracks original and split-adjusted quantities/cost basis.
// Parent entity in CoreData: BaseFinancialRecord

@objc(Lot)
public class Lot: BaseFinancialRecord, Identifiable {

    // MARK: - Identity

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID
    @NSManaged public var lotNumber: Int32

    // MARK: - Quantity & Basis

    /// Original quantity at time of purchase — preserved forever, never changed by splits.
    @NSManaged public var originalQtyRaw: NSDecimalNumber

    /// Original cost basis per share at time of purchase — preserved forever.
    @NSManaged public var originalCostBasisPerShareRaw: NSDecimalNumber

    /// Current quantity after all splits.
    @NSManaged public var splitAdjustedQtyRaw: NSDecimalNumber

    /// Current per-share cost basis after splits.
    @NSManaged public var splitAdjustedCostBasisPerShareRaw: NSDecimalNumber

    /// Total cost basis = originalQty × originalCostBasisPerShare (unchanged by splits).
    @NSManaged public var totalCostBasisRaw: NSDecimalNumber

    /// Remaining quantity available for sale. Decreases on partial sells.
    @NSManaged public var remainingQtyRaw: NSDecimalNumber

    // MARK: - Dates

    /// Trade date — used for IRS holding period. Never use settlementDate for tax purposes.
    @NSManaged public var purchaseDate: Date

    /// Informational only — not used for tax calculations.
    @NSManaged public var settlementDate: Date?

    // MARK: - State

    @NSManaged public var isClosed: Bool
    @NSManaged public var isSoftDeleted: Bool
    @NSManaged public var deletedAt: Date?
    @NSManaged public var createdAt: Date

    // MARK: - Source & Metadata

    /// How this lot was created.
    @NSManaged public var lotSourceRaw: String

    /// If created by a DRIP, the DividendEvent ID.
    @NSManaged public var linkedDividendEventId: UUID?

    /// JSON-encoded [UUID] of SplitEvent IDs applied to this lot.
    @NSManaged public var splitHistoryData: Data?

    /// Override for special tax treatment (standard / section1256 / crypto).
    @NSManaged public var taxTreatmentOverrideRaw: String?

    /// Human-readable source reference — e.g. "AAPL Sell", "Manual Deposit".
    /// Set on Cash lots to identify where the credit originated.
    @NSManaged public var sourceNote: String?

    // MARK: - Lifecycle

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
        lotNumber = 1
        isClosed = false
        isSoftDeleted = false
        lotSourceRaw = LotSource.manual.rawValue
        originalQtyRaw = .zero
        originalCostBasisPerShareRaw = .zero
        splitAdjustedQtyRaw = .zero
        splitAdjustedCostBasisPerShareRaw = .zero
        totalCostBasisRaw = .zero
        remainingQtyRaw = .zero
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension Lot {
    var originalQty: Decimal {
        get { originalQtyRaw.decimalValue }
        set { originalQtyRaw = newValue as NSDecimalNumber; markModified() }
    }

    var originalCostBasisPerShare: Decimal {
        get { originalCostBasisPerShareRaw.decimalValue }
        set { originalCostBasisPerShareRaw = newValue as NSDecimalNumber; markModified() }
    }

    var splitAdjustedQty: Decimal {
        get { splitAdjustedQtyRaw.decimalValue }
        set { splitAdjustedQtyRaw = newValue as NSDecimalNumber; markModified() }
    }

    var splitAdjustedCostBasisPerShare: Decimal {
        get { splitAdjustedCostBasisPerShareRaw.decimalValue }
        set { splitAdjustedCostBasisPerShareRaw = newValue as NSDecimalNumber; markModified() }
    }

    var totalCostBasis: Decimal {
        get { totalCostBasisRaw.decimalValue }
        set { totalCostBasisRaw = newValue as NSDecimalNumber; markModified() }
    }

    var remainingQty: Decimal {
        get { remainingQtyRaw.decimalValue }
        set { remainingQtyRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Enum Wrappers

extension Lot {
    var lotSource: LotSource {
        get { LotSource(rawValue: lotSourceRaw) ?? .manual }
        set { lotSourceRaw = newValue.rawValue; markModified() }
    }

    var taxTreatmentOverride: TaxTreatment? {
        get { taxTreatmentOverrideRaw.flatMap(TaxTreatment.init) }
        set { taxTreatmentOverrideRaw = newValue?.rawValue; markModified() }
    }
}

// MARK: - Split History

extension Lot {
    var splitHistory: [UUID] {
        get {
            guard let data = splitHistoryData,
                  let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
                return []
            }
            return ids
        }
        set {
            splitHistoryData = try? JSONEncoder().encode(newValue)
            markModified()
        }
    }

    var hasSplitAdjustments: Bool { !splitHistory.isEmpty }
}

// MARK: - Computed Properties

extension Lot {
    /// Whether this lot qualifies for long-term capital gains treatment as of today.
    var isLongTerm: Bool {
        Date().isLongTerm(purchasedOn: purchaseDate)
    }

    /// Days until LT status is achieved. nil if already LT.
    var daysToLongTerm: Int? {
        Date().daysToLongTerm(purchasedOn: purchaseDate)
    }

    /// Calendar days held from purchaseDate to today.
    var daysHeld: Int {
        Date().daysHeld(from: purchaseDate)
    }

    /// Progress bar fill [0, 1] toward LT.
    var ltProgress: Double {
        Date().ltProgress(purchasedOn: purchaseDate)
    }

    /// Whether this lot is within the gold advisory window (≤ 60 days to LT).
    var isApproachingLongTerm: Bool {
        guard let days = daysToLongTerm else { return false }
        return days <= 60
    }

    /// The exact date on which LT status is first achieved.
    var longTermQualifyingDate: Date? {
        Date.longTermQualifyingDate(purchasedOn: purchaseDate)
    }

    /// The lot's contribution to portfolio value, accounting for direction.
    /// Long: current market value.  Short: net equity (premium received − current cost-to-close).
    func equityContribution(at price: Decimal, multiplier: Decimal = 1, pnlDirection: Decimal = 1) -> Decimal {
        if pnlDirection < 0 {
            // Short option: net equity = (costBasis − currentPrice) × qty × 100
            return unrealizedPnL(at: price, multiplier: multiplier) * -1
        }
        return marketValue(at: price, multiplier: multiplier)
    }

    /// Market value of this lot at a given price.
    /// Pass multiplier: 100 for options lots (1 contract = 100 shares).
    func marketValue(at price: Decimal, multiplier: Decimal = 1) -> Decimal {
        (remainingQty * price * multiplier).rounded(to: 2)
    }

    /// Unrealized P&L at a given price.
    /// Pass multiplier: 100 for options lots (1 contract = 100 shares).
    func unrealizedPnL(at price: Decimal, multiplier: Decimal = 1) -> Decimal {
        let value = marketValue(at: price, multiplier: multiplier)
        let basis = (remainingQty * splitAdjustedCostBasisPerShare * multiplier).rounded(to: 2)
        return (value - basis).rounded(to: 2)
    }

    /// Unrealized P&L percentage.
    /// Pass multiplier: 100 for options lots (1 contract = 100 shares).
    func unrealizedPnLPercent(at price: Decimal, multiplier: Decimal = 1) -> Decimal? {
        let basis = remainingQty * splitAdjustedCostBasisPerShare * multiplier
        return unrealizedPnL(at: price, multiplier: multiplier).divided(by: basis).map { ($0 * 100).rounded(to: 2) }
    }
}

// MARK: - Soft Delete

extension Lot {
    func softDelete(reason: DeletionReason = .userDeleted) {
        isSoftDeleted = true
        deletedAt = Date()
        markModified()
    }
}

// MARK: - Factory

extension Lot {
    /// Create a new Lot in the given context for a buy transaction.
    /// For options lots, pass contractMultiplier: 100 so that totalCostBasis reflects true dollar cost
    /// (e.g. 2 contracts × $5 premium × 100 + fee = $1,000 + fee).
    static func create(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        lotNumber: Int32,
        quantity: Decimal,
        costBasisPerShare: Decimal,
        purchaseDate: Date,
        fee: Decimal = 0,
        source: LotSource = .manual,
        contractMultiplier: Decimal = 1
    ) -> Lot {
        let lot = Lot(context: context)
        lot.holdingId = holdingId
        lot.lotNumber = lotNumber

        let totalShares = quantity * contractMultiplier
        let feePerShare = totalShares > 0 ? fee / totalShares : 0
        let adjustedBasis = costBasisPerShare + feePerShare

        lot.originalQty = quantity
        lot.originalCostBasisPerShare = adjustedBasis
        lot.splitAdjustedQty = quantity
        lot.splitAdjustedCostBasisPerShare = adjustedBasis
        lot.totalCostBasis = (quantity * costBasisPerShare * contractMultiplier + fee).rounded(to: 2)
        lot.remainingQty = quantity
        lot.purchaseDate = purchaseDate
        lot.lotSource = source
        return lot
    }
}

// MARK: - Fetch Requests

extension Lot {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Lot> {
        NSFetchRequest<Lot>(entityName: "Lot")
    }

    static func openLots(for holdingId: UUID) -> NSFetchRequest<Lot> {
        let request = fetchRequest()
        request.predicate = NSPredicate(
            format: "holdingId == %@ AND isClosed == NO AND isSoftDeleted == NO",
            holdingId as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Lot.purchaseDate, ascending: true)]
        return request
    }

    static func closedLots(for holdingId: UUID) -> NSFetchRequest<Lot> {
        let request = fetchRequest()
        request.predicate = NSPredicate(
            format: "holdingId == %@ AND isClosed == YES AND isSoftDeleted == NO",
            holdingId as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Lot.purchaseDate, ascending: false)]
        return request
    }
}

// MARK: - Enums

enum LotSource: String, CaseIterable, Codable {
    case manual  = "manual"
    case drip    = "drip"
    case `import` = "import"
    case split   = "split"
}

enum TaxTreatment: String, CaseIterable, Codable {
    case standard    = "standard"
    case section1256 = "section1256"
    case crypto      = "crypto"
}

enum DeletionReason: String, Codable {
    case userDeleted   = "userDeleted"
    case importRollback = "importRollback"
    case splitReversal = "splitReversal"
}
