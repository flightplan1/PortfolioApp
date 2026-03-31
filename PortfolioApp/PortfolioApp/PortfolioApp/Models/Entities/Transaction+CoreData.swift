import Foundation
import CoreData

// MARK: - Transaction
// Records every buy, sell, dividend, DRIP, split, or transfer event.
// IMPORTANT: Never hard-delete transactions. Always use soft delete.
// Parent entity in CoreData: BaseFinancialRecord

@objc(Transaction)
public class Transaction: BaseFinancialRecord {

    // MARK: - Identity

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID
    @NSManaged public var lotId: UUID?        // Links to specific lot (for sells)

    // MARK: - Transaction Detail

    /// Transaction type. See TransactionType enum.
    @NSManaged public var typeRaw: String

    /// Trade date — IRS holding period basis. Always use this for tax calculations.
    /// Never use settlementDate for tax purposes.
    @NSManaged public var tradeDate: Date

    /// Informational only — T+1 for most equities. Not used for tax calculations.
    @NSManaged public var settlementDate: Date?

    @NSManaged public var quantityRaw: NSDecimalNumber
    @NSManaged public var pricePerShareRaw: NSDecimalNumber
    @NSManaged public var totalAmountRaw: NSDecimalNumber
    @NSManaged public var feeRaw: NSDecimalNumber

    // MARK: - Lot Method

    @NSManaged public var lotMethodRaw: String

    // MARK: - Import

    @NSManaged public var importSessionId: UUID?

    // MARK: - Realized Tax (stored at time of sale — v2)

    @NSManaged public var realizedGainRaw: NSDecimalNumber
    @NSManaged public var isLongTerm:      Bool
    @NSManaged public var federalTaxRaw:   NSDecimalNumber
    @NSManaged public var niitRaw:         NSDecimalNumber
    @NSManaged public var stateTaxRaw:     NSDecimalNumber
    @NSManaged public var cityTaxRaw:      NSDecimalNumber
    @NSManaged public var totalTaxRaw:     NSDecimalNumber

    // MARK: - Notes

    @NSManaged public var notes: String?

    // MARK: - Soft Delete

    @NSManaged public var isSoftDeleted: Bool
    @NSManaged public var deletedAt: Date?
    @NSManaged public var deletionReasonRaw: String?

    // MARK: - Metadata

    @NSManaged public var createdAt: Date

    // MARK: - Lifecycle

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
        tradeDate = Date()
        isSoftDeleted = false
        typeRaw = TransactionType.buy.rawValue
        lotMethodRaw = LotMethod.fifo.rawValue
        quantityRaw = .zero
        pricePerShareRaw = .zero
        totalAmountRaw = .zero
        feeRaw = .zero
        realizedGainRaw = .zero
        isLongTerm = false
        federalTaxRaw = .zero
        niitRaw = .zero
        stateTaxRaw = .zero
        cityTaxRaw = .zero
        totalTaxRaw = .zero
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension Transaction {
    var quantity: Decimal {
        get { quantityRaw.decimalValue }
        set { quantityRaw = newValue as NSDecimalNumber; markModified() }
    }

    var pricePerShare: Decimal {
        get { pricePerShareRaw.decimalValue }
        set { pricePerShareRaw = newValue as NSDecimalNumber; markModified() }
    }

    var totalAmount: Decimal {
        get { totalAmountRaw.decimalValue }
        set { totalAmountRaw = newValue as NSDecimalNumber; markModified() }
    }

    var fee: Decimal {
        get { feeRaw.decimalValue }
        set { feeRaw = newValue as NSDecimalNumber; markModified() }
    }

    var realizedGain: Decimal {
        get { realizedGainRaw.decimalValue }
        set { realizedGainRaw = newValue as NSDecimalNumber; markModified() }
    }

    var federalTax: Decimal {
        get { federalTaxRaw.decimalValue }
        set { federalTaxRaw = newValue as NSDecimalNumber; markModified() }
    }

    var niit: Decimal {
        get { niitRaw.decimalValue }
        set { niitRaw = newValue as NSDecimalNumber; markModified() }
    }

    var stateTax: Decimal {
        get { stateTaxRaw.decimalValue }
        set { stateTaxRaw = newValue as NSDecimalNumber; markModified() }
    }

    var cityTax: Decimal {
        get { cityTaxRaw.decimalValue }
        set { cityTaxRaw = newValue as NSDecimalNumber; markModified() }
    }

    var totalTax: Decimal {
        get { totalTaxRaw.decimalValue }
        set { totalTaxRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Enum Wrappers

extension Transaction {
    var type: TransactionType {
        get { TransactionType(rawValue: typeRaw) ?? .buy }
        set { typeRaw = newValue.rawValue; markModified() }
    }

    var lotMethod: LotMethod {
        get { LotMethod(rawValue: lotMethodRaw) ?? .fifo }
        set { lotMethodRaw = newValue.rawValue; markModified() }
    }

    var deletionReason: DeletionReason? {
        get { deletionReasonRaw.flatMap(DeletionReason.init) }
        set { deletionReasonRaw = newValue?.rawValue; markModified() }
    }
}

// MARK: - Soft Delete

extension Transaction {
    func softDelete(reason: DeletionReason = .userDeleted) {
        isSoftDeleted = true
        deletedAt = Date()
        deletionReason = reason
        markModified()
    }
}

// MARK: - Computed Properties

extension Transaction {
    /// Whether this transaction represents a taxable event.
    var isTaxableEvent: Bool {
        switch type {
        case .sell, .dividend, .drip: return true
        default: return false
        }
    }

    /// Whether this is a buy-side transaction (creates or adds to a lot).
    var isBuy: Bool {
        switch type {
        case .buy, .drip, .transferIn: return true
        default: return false
        }
    }

    var displayDescription: String {
        switch type {
        case .buy:         return "Buy"
        case .sell:        return "Sell"
        case .dividend:    return "Dividend"
        case .drip:        return "DRIP Reinvestment"
        case .split:       return "Stock Split"
        case .transferIn:  return "Transfer In"
        case .transferOut: return "Transfer Out"
        }
    }
}

// MARK: - Factory

extension Transaction {
    static func createBuy(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        lotId: UUID,
        quantity: Decimal,
        pricePerShare: Decimal,
        fee: Decimal = 0,
        tradeDate: Date,
        lotMethod: LotMethod = .fifo
    ) -> Transaction {
        let tx = Transaction(context: context)
        tx.holdingId = holdingId
        tx.lotId = lotId
        tx.type = .buy
        tx.quantity = quantity
        tx.pricePerShare = pricePerShare
        tx.fee = fee
        tx.totalAmount = (quantity * pricePerShare + fee).rounded(to: 2)
        tx.tradeDate = tradeDate
        tx.settlementDate = tradeDate.settlementDateT1
        tx.lotMethod = lotMethod
        return tx
    }

    /// Creates a sell/close transaction.
    /// - Pass `totalAmountOverride` for options closing:
    ///   - STC (sell to close long): override with `qty × price × 100 − fee` (proceeds received)
    ///   - BTC (buy to close short): override with `qty × price × 100 + fee` (cost paid)
    ///   These values are used by realizedPnLStats to compute P&L correctly with pnlDirection.
    static func createSell(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        lotId: UUID,
        quantity: Decimal,
        pricePerShare: Decimal,
        fee: Decimal = 0,
        tradeDate: Date,
        totalAmountOverride: Decimal? = nil,
        taxEstimate: TaxEstimate? = nil
    ) -> Transaction {
        let tx = Transaction(context: context)
        tx.holdingId = holdingId
        tx.lotId = lotId
        tx.type = .sell
        tx.quantity = quantity
        tx.pricePerShare = pricePerShare
        tx.fee = fee
        tx.totalAmount = totalAmountOverride ?? (quantity * pricePerShare - fee).rounded(to: 2)
        tx.tradeDate = tradeDate
        tx.settlementDate = tradeDate.settlementDateT1
        if let est = taxEstimate {
            tx.realizedGain = est.gain
            tx.isLongTerm   = est.isLongTerm
            tx.federalTax   = est.federalTax
            tx.niit         = est.niit
            tx.stateTax     = est.stateTax
            tx.cityTax      = est.cityTax
            tx.totalTax     = est.totalTax
        }
        return tx
    }
}

// MARK: - Fetch Requests

extension Transaction {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Transaction> {
        NSFetchRequest<Transaction>(entityName: "Transaction")
    }

    static func activeTransactions(for holdingId: UUID) -> NSFetchRequest<Transaction> {
        let request = fetchRequest()
        request.predicate = NSPredicate(
            format: "holdingId == %@ AND isSoftDeleted == NO",
            holdingId as CVarArg
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Transaction.tradeDate, ascending: false)]
        return request
    }
}

// MARK: - Enums

enum TransactionType: String, CaseIterable, Codable {
    case buy         = "buy"
    case sell        = "sell"
    case dividend    = "dividend"
    case drip        = "drip"
    case split       = "split"
    case transferIn  = "transferIn"
    case transferOut = "transferOut"
}

enum LotMethod: String, CaseIterable, Codable {
    case fifo         = "fifo"
    case lifo         = "lifo"
    case highestCost  = "highestCost"
    case lowestCost   = "lowestCost"
    case specificLot  = "specificLot"

    var displayName: String {
        switch self {
        case .fifo:        return "FIFO (First In, First Out)"
        case .lifo:        return "LIFO (Last In, First Out)"
        case .highestCost: return "Highest Cost"
        case .lowestCost:  return "Lowest Cost"
        case .specificLot: return "Specific Lot"
        }
    }

    var shortName: String {
        switch self {
        case .fifo:        return "FIFO"
        case .lifo:        return "LIFO"
        case .highestCost: return "Highest"
        case .lowestCost:  return "Lowest"
        case .specificLot: return "Specific"
        }
    }
}
