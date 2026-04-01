import Foundation
import CoreData

// MARK: - SplitEvent
// Records a stock split applied to a Holding. CloudKit synced.
// originalQty / originalCostBasisPerShare on each Lot are preserved forever.
// splitAdjustedQty / splitAdjustedCostBasisPerShare are updated by SplitService.

@objc(SplitEvent)
public class SplitEvent: BaseFinancialRecord, Identifiable {

    // MARK: - Identity

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID
    @NSManaged public var symbol: String

    // MARK: - Split Details

    @NSManaged public var splitDate: Date
    @NSManaged public var ratioNumerator: Int32      // e.g. 10 in a 10:1 split
    @NSManaged public var ratioDenominator: Int32    // e.g.  1 in a 10:1 split
    @NSManaged public var splitMultiplierRaw: NSDecimalNumber  // numerator / denominator
    @NSManaged public var isForward: Bool            // true = more shares (e.g. 2:1), false = reverse

    // MARK: - Audit Trail

    @NSManaged public var snapshotBeforeSharesRaw: NSDecimalNumber
    @NSManaged public var snapshotAfterSharesRaw: NSDecimalNumber
    @NSManaged public var appliedAt: Date

    // MARK: - Metadata

    @NSManaged public var entryMethodRaw: String    // "auto" | "manual"

    // MARK: - Lifecycle

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        symbol = ""
        ratioNumerator = 2
        ratioDenominator = 1
        isForward = true
        splitMultiplierRaw = NSDecimalNumber(value: 2)
        snapshotBeforeSharesRaw = .zero
        snapshotAfterSharesRaw = .zero
        appliedAt = Date()
        entryMethodRaw = SplitEntryMethod.manual.rawValue
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension SplitEvent {
    var splitMultiplier: Decimal {
        get { splitMultiplierRaw.decimalValue }
        set { splitMultiplierRaw = newValue as NSDecimalNumber; markModified() }
    }

    var snapshotBeforeShares: Decimal {
        get { snapshotBeforeSharesRaw.decimalValue }
        set { snapshotBeforeSharesRaw = newValue as NSDecimalNumber; markModified() }
    }

    var snapshotAfterShares: Decimal {
        get { snapshotAfterSharesRaw.decimalValue }
        set { snapshotAfterSharesRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Enum Wrapper

extension SplitEvent {
    var entryMethod: SplitEntryMethod {
        get { SplitEntryMethod(rawValue: entryMethodRaw) ?? .manual }
        set { entryMethodRaw = newValue.rawValue; markModified() }
    }
}

// MARK: - Computed

extension SplitEvent {
    /// Human-readable ratio string, e.g. "10:1" or "1:10"
    var ratioString: String { "\(ratioNumerator):\(ratioDenominator)" }

    /// True when this is a reverse split (fewer shares after).
    var isReverse: Bool { !isForward }
}

// MARK: - Factory

extension SplitEvent {
    static func create(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        symbol: String,
        splitDate: Date,
        numerator: Int,
        denominator: Int,
        entryMethod: SplitEntryMethod = .manual
    ) -> SplitEvent {
        let event = SplitEvent(context: context)
        event.holdingId = holdingId
        event.symbol = symbol
        event.splitDate = splitDate
        event.ratioNumerator = Int32(numerator)
        event.ratioDenominator = Int32(denominator)
        let multiplier = Decimal(numerator) / Decimal(denominator)
        event.splitMultiplier = multiplier
        event.isForward = multiplier >= 1
        event.entryMethod = entryMethod
        event.appliedAt = Date()
        return event
    }
}

// MARK: - Fetch Requests

extension SplitEvent {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SplitEvent> {
        NSFetchRequest<SplitEvent>(entityName: "SplitEvent")
    }

    static func forHolding(_ holdingId: UUID) -> NSFetchRequest<SplitEvent> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \SplitEvent.splitDate, ascending: false)]
        return request
    }

    static func all() -> NSFetchRequest<SplitEvent> {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \SplitEvent.splitDate, ascending: false)]
        return request
    }
}

// MARK: - Enums

enum SplitEntryMethod: String, Codable {
    case auto   = "auto"
    case manual = "manual"
}
