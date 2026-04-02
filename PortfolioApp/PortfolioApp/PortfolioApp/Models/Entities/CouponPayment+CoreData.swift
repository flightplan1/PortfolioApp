import Foundation
import CoreData

// MARK: - CouponPayment
// Records a single scheduled (or received) coupon interest payment
// for a T-Note, T-Bond, or TIPS position.

@objc(CouponPayment)
public class CouponPayment: BaseFinancialRecord, Identifiable {

    @NSManaged public var id: UUID
    @NSManaged public var treasuryPositionId: UUID
    @NSManaged public var holdingId: UUID             // denormalized for easy FetchRequest
    @NSManaged public var scheduledDate: Date
    @NSManaged public var amountRaw: NSDecimalNumber
    @NSManaged public var isReceived: Bool
    @NSManaged public var receivedDate: Date?
    @NSManaged public var linkedCashPositionId: UUID?

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        amountRaw = .zero
        isReceived = false
        markModified()
    }
}

// MARK: - Decimal Wrapper

extension CouponPayment {
    var amount: Decimal {
        get { amountRaw.decimalValue }
        set { amountRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Factory

extension CouponPayment {
    /// Generate the full coupon schedule for a position, creating CouponPayment records.
    static func generateSchedule(
        for position: TreasuryPosition,
        in context: NSManagedObjectContext
    ) {
        guard position.couponFrequency != .zero else { return }
        let dates = TreasuryEngine.couponDates(
            from: position.purchaseDate,
            to: position.maturityDate,
            frequency: position.couponFrequency
        )
        for date in dates {
            let payment = CouponPayment(context: context)
            payment.treasuryPositionId = position.id
            payment.holdingId = position.holdingId
            payment.scheduledDate = date
            payment.amount = position.perPaymentCouponAmount
            payment.isReceived = date < Date()
            if date < Date() {
                payment.receivedDate = date
            }
        }
    }

    /// Mark a payment as received and optionally credit cash.
    func markReceived(in context: NSManagedObjectContext, creditCash: Bool = false) {
        isReceived = true
        receivedDate = Date()
        if creditCash {
            CashLedgerService.credit(amount: amount, note: "Coupon payment", in: context)
        }
    }
}

// MARK: - Fetch Requests

extension CouponPayment {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CouponPayment> {
        NSFetchRequest<CouponPayment>(entityName: "CouponPayment")
    }

    static func forPosition(_ positionId: UUID) -> NSFetchRequest<CouponPayment> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "treasuryPositionId == %@", positionId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \CouponPayment.scheduledDate, ascending: true)]
        return req
    }

    static func forHolding(_ holdingId: UUID) -> NSFetchRequest<CouponPayment> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \CouponPayment.scheduledDate, ascending: true)]
        return req
    }

    static func pendingPayments() -> NSFetchRequest<CouponPayment> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "isReceived == NO AND scheduledDate <= %@", Date() as NSDate)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \CouponPayment.scheduledDate, ascending: true)]
        return req
    }
}
