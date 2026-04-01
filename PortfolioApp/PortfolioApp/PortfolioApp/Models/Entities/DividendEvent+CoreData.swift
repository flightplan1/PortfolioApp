import Foundation
import CoreData

// MARK: - DividendEvent
// Records a single dividend payment for a holding.
// isReinvested = true → DRIP: a new Lot was created and linkedLotId is set.
// isReinvested = false → Cash: grossAmount credited to cash (linkedCashPositionId if tracked).

@objc(DividendEvent)
public class DividendEvent: BaseFinancialRecord, Identifiable {

    // MARK: - Identity

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID
    @NSManaged public var symbol: String

    // MARK: - Payment Details

    @NSManaged public var payDate: Date
    @NSManaged public var exDividendDate: Date?
    @NSManaged public var dividendPerShareRaw: NSDecimalNumber
    @NSManaged public var sharesHeldRaw: NSDecimalNumber
    @NSManaged public var grossAmountRaw: NSDecimalNumber

    // MARK: - DRIP

    @NSManaged public var isReinvested: Bool
    @NSManaged public var reinvestedSharesRaw: NSDecimalNumber
    @NSManaged public var reinvestedPricePerShareRaw: NSDecimalNumber

    // MARK: - Links

    /// Set when isReinvested == true — the lot created by DRIP reinvestment.
    @NSManaged public var linkedLotId: UUID?

    /// Set when isReinvested == false — the cash position credited.
    @NSManaged public var linkedCashPositionId: UUID?

    // MARK: - Metadata

    @NSManaged public var entryMethodRaw: String    // "auto" | "manual"
    @NSManaged public var isQualified: Bool         // stored, not yet surfaced in UI

    // MARK: - Lifecycle

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        symbol = ""
        isReinvested = false
        isQualified = false
        entryMethodRaw = DividendEntryMethod.manual.rawValue
        dividendPerShareRaw = .zero
        sharesHeldRaw = .zero
        grossAmountRaw = .zero
        reinvestedSharesRaw = .zero
        reinvestedPricePerShareRaw = .zero
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension DividendEvent {
    var dividendPerShare: Decimal {
        get { dividendPerShareRaw.decimalValue }
        set { dividendPerShareRaw = newValue as NSDecimalNumber; markModified() }
    }

    var sharesHeld: Decimal {
        get { sharesHeldRaw.decimalValue }
        set { sharesHeldRaw = newValue as NSDecimalNumber; markModified() }
    }

    var grossAmount: Decimal {
        get { grossAmountRaw.decimalValue }
        set { grossAmountRaw = newValue as NSDecimalNumber; markModified() }
    }

    var reinvestedShares: Decimal {
        get { reinvestedSharesRaw.decimalValue }
        set { reinvestedSharesRaw = newValue as NSDecimalNumber; markModified() }
    }

    var reinvestedPricePerShare: Decimal {
        get { reinvestedPricePerShareRaw.decimalValue }
        set { reinvestedPricePerShareRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Enum Wrapper

extension DividendEvent {
    var entryMethod: DividendEntryMethod {
        get { DividendEntryMethod(rawValue: entryMethodRaw) ?? .manual }
        set { entryMethodRaw = newValue.rawValue; markModified() }
    }
}

// MARK: - Factory

extension DividendEvent {
    /// Create a cash dividend (not reinvested).
    static func createCash(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        symbol: String,
        payDate: Date,
        exDividendDate: Date?,
        dividendPerShare: Decimal,
        sharesHeld: Decimal
    ) -> DividendEvent {
        let event = DividendEvent(context: context)
        event.holdingId = holdingId
        event.symbol = symbol
        event.payDate = payDate
        event.exDividendDate = exDividendDate
        event.dividendPerShare = dividendPerShare
        event.sharesHeld = sharesHeld
        event.grossAmount = (dividendPerShare * sharesHeld).rounded(to: 2)
        event.isReinvested = false
        event.entryMethod = .manual
        return event
    }

    /// Create a DRIP dividend — caller must also create the Lot and pass its id.
    static func createDRIP(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        symbol: String,
        payDate: Date,
        exDividendDate: Date?,
        dividendPerShare: Decimal,
        sharesHeld: Decimal,
        reinvestedShares: Decimal,
        reinvestedPricePerShare: Decimal,
        linkedLotId: UUID
    ) -> DividendEvent {
        let event = DividendEvent(context: context)
        event.holdingId = holdingId
        event.symbol = symbol
        event.payDate = payDate
        event.exDividendDate = exDividendDate
        event.dividendPerShare = dividendPerShare
        event.sharesHeld = sharesHeld
        event.grossAmount = (dividendPerShare * sharesHeld).rounded(to: 2)
        event.isReinvested = true
        event.reinvestedShares = reinvestedShares
        event.reinvestedPricePerShare = reinvestedPricePerShare
        event.linkedLotId = linkedLotId
        event.entryMethod = .manual
        return event
    }
}

// MARK: - Fetch Requests

extension DividendEvent {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DividendEvent> {
        NSFetchRequest<DividendEvent>(entityName: "DividendEvent")
    }

    static func forHolding(_ holdingId: UUID) -> NSFetchRequest<DividendEvent> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DividendEvent.payDate, ascending: false)]
        return request
    }

    static func forYear(_ year: Int) -> NSFetchRequest<DividendEvent> {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end   = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        let request = fetchRequest()
        request.predicate = NSPredicate(
            format: "payDate >= %@ AND payDate < %@",
            start as NSDate, end as NSDate
        )
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DividendEvent.payDate, ascending: false)]
        return request
    }
}

// MARK: - Enums

enum DividendEntryMethod: String, Codable {
    case auto   = "auto"
    case manual = "manual"
}
