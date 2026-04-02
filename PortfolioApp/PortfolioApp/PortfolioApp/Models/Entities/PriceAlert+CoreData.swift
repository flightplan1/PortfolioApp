import Foundation
import CoreData

// MARK: - AlertDirection

enum AlertDirection: String, CaseIterable {
    case above = "above"
    case below = "below"

    var label: String {
        switch self {
        case .above: return "Above"
        case .below: return "Below"
        }
    }

    var icon: String {
        switch self {
        case .above: return "arrow.up.circle.fill"
        case .below: return "arrow.down.circle.fill"
        }
    }
}

// MARK: - PriceAlert

@objc(PriceAlert)
public class PriceAlert: BaseFinancialRecord, Identifiable {

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID
    @NSManaged public var symbol: String
    @NSManaged public var targetPriceRaw: NSDecimalNumber
    @NSManaged public var directionRaw: String
    @NSManaged public var isTriggered: Bool
    @NSManaged public var createdAt: Date
    @NSManaged public var triggeredAt: Date?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        symbol = ""
        targetPriceRaw = .zero
        directionRaw = AlertDirection.above.rawValue
        isTriggered = false
        createdAt = Date()
        markModified()
    }
}

// MARK: - Computed

extension PriceAlert {
    var targetPrice: Decimal {
        get { targetPriceRaw.decimalValue }
        set { targetPriceRaw = newValue as NSDecimalNumber; markModified() }
    }

    var direction: AlertDirection {
        get { AlertDirection(rawValue: directionRaw) ?? .above }
        set { directionRaw = newValue.rawValue; markModified() }
    }

    /// True if the current price satisfies this alert's condition.
    func isConditionMet(currentPrice: Decimal) -> Bool {
        switch direction {
        case .above: return currentPrice >= targetPrice
        case .below: return currentPrice <= targetPrice
        }
    }
}

// MARK: - Factory

extension PriceAlert {
    static func create(
        in context: NSManagedObjectContext,
        holding: Holding,
        targetPrice: Decimal,
        direction: AlertDirection
    ) -> PriceAlert {
        let alert = PriceAlert(context: context)
        alert.holdingId = holding.id
        alert.symbol = holding.symbol
        alert.targetPrice = targetPrice
        alert.direction = direction
        return alert
    }
}

// MARK: - Fetch Requests

extension PriceAlert {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<PriceAlert> {
        NSFetchRequest<PriceAlert>(entityName: "PriceAlert")
    }

    /// All active (non-triggered) alerts for a holding.
    static func active(for holdingId: UUID) -> NSFetchRequest<PriceAlert> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@ AND isTriggered == NO", holdingId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \PriceAlert.createdAt, ascending: false)]
        return req
    }

    /// All alerts (active + triggered) for a holding, newest first.
    static func all(for holdingId: UUID) -> NSFetchRequest<PriceAlert> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \PriceAlert.createdAt, ascending: false)]
        return req
    }

    /// All untriggered alerts across all holdings — used by PriceAlertService.
    static func allUntriggered() -> NSFetchRequest<PriceAlert> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "isTriggered == NO")
        return req
    }
}
