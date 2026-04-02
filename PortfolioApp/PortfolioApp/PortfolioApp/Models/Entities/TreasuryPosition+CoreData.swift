import Foundation
import CoreData

// MARK: - CouponFrequency

enum CouponFrequency: String, CaseIterable {
    case zero       = "zero"
    case semiannual = "semiannual"
    case annual     = "annual"

    var displayName: String {
        switch self {
        case .zero:       return "Zero Coupon"
        case .semiannual: return "Semi-Annual"
        case .annual:     return "Annual"
        }
    }

    var paymentsPerYear: Int {
        switch self {
        case .zero:       return 0
        case .semiannual: return 2
        case .annual:     return 1
        }
    }

    static func `for`(_ instrument: TreasuryInstrument) -> CouponFrequency {
        switch instrument {
        case .tBill, .iBond: return .zero
        case .tNote, .tBond, .tips: return .semiannual
        }
    }
}

// MARK: - TreasuryPosition

@objc(TreasuryPosition)
public class TreasuryPosition: BaseFinancialRecord, Identifiable {

    @NSManaged public var id: UUID
    @NSManaged public var holdingId: UUID

    // Instrument
    @NSManaged public var instrumentTypeRaw: String
    @NSManaged public var cusip: String?

    // Principal
    @NSManaged public var faceValueRaw: NSDecimalNumber      // par / face value
    @NSManaged public var purchasePriceRaw: NSDecimalNumber  // total purchase price paid
    @NSManaged public var purchaseDate: Date
    @NSManaged public var maturityDate: Date

    // Coupon
    @NSManaged public var couponRateRaw: NSDecimalNumber     // annual rate, e.g. 0.045 = 4.5%
    @NSManaged public var couponFrequencyRaw: String         // CouponFrequency raw value

    // Yield
    @NSManaged public var ytmAtPurchaseRaw: NSDecimalNumber  // calculated at time of purchase

    // Tax treatment (federal securities are state/city exempt by default)
    @NSManaged public var isStateExempt: Bool
    @NSManaged public var isCityExempt: Bool

    // Maturity
    @NSManaged public var isMatured: Bool
    @NSManaged public var maturedAt: Date?
    @NSManaged public var maturityProceedsRaw: NSDecimalNumber
    @NSManaged public var maturityAlertScheduled: Bool

    // TIPS-specific
    @NSManaged public var inflationAdjustedPrincipalRaw: NSDecimalNumber
    @NSManaged public var lastCPIUpdateDate: Date?

    // I-Bond–specific
    @NSManaged public var fixedRateRaw: NSDecimalNumber
    @NSManaged public var currentInflationRateRaw: NSDecimalNumber  // semiannual CPI rate
    @NSManaged public var compositeRateRaw: NSDecimalNumber
    @NSManaged public var ibondIssueDate: Date?
    @NSManaged public var lockupExpiryDate: Date?   // issue date + 1 yr — cannot redeem before
    @NSManaged public var penaltyFreeDate: Date?    // issue date + 5 yr — no 3-month penalty after

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        instrumentTypeRaw = TreasuryInstrument.tBill.rawValue
        faceValueRaw = .zero
        purchasePriceRaw = .zero
        purchaseDate = Date()
        maturityDate = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
        couponRateRaw = .zero
        couponFrequencyRaw = CouponFrequency.zero.rawValue
        ytmAtPurchaseRaw = .zero
        isStateExempt = true
        isCityExempt = true
        isMatured = false
        maturityAlertScheduled = false
        maturityProceedsRaw = .zero
        inflationAdjustedPrincipalRaw = .zero
        fixedRateRaw = .zero
        currentInflationRateRaw = .zero
        compositeRateRaw = .zero
        markModified()
    }
}

// MARK: - Decimal Wrappers

extension TreasuryPosition {
    var faceValue: Decimal {
        get { faceValueRaw.decimalValue }
        set { faceValueRaw = newValue as NSDecimalNumber; markModified() }
    }

    var purchasePrice: Decimal {
        get { purchasePriceRaw.decimalValue }
        set { purchasePriceRaw = newValue as NSDecimalNumber; markModified() }
    }

    var couponRate: Decimal {
        get { couponRateRaw.decimalValue }
        set { couponRateRaw = newValue as NSDecimalNumber; markModified() }
    }

    var ytmAtPurchase: Decimal {
        get { ytmAtPurchaseRaw.decimalValue }
        set { ytmAtPurchaseRaw = newValue as NSDecimalNumber; markModified() }
    }

    var maturityProceeds: Decimal {
        get { maturityProceedsRaw.decimalValue }
        set { maturityProceedsRaw = newValue as NSDecimalNumber; markModified() }
    }

    var inflationAdjustedPrincipal: Decimal {
        get { inflationAdjustedPrincipalRaw.decimalValue }
        set { inflationAdjustedPrincipalRaw = newValue as NSDecimalNumber; markModified() }
    }

    var fixedRate: Decimal {
        get { fixedRateRaw.decimalValue }
        set { fixedRateRaw = newValue as NSDecimalNumber; markModified() }
    }

    var currentInflationRate: Decimal {
        get { currentInflationRateRaw.decimalValue }
        set { currentInflationRateRaw = newValue as NSDecimalNumber; markModified() }
    }

    var compositeRate: Decimal {
        get { compositeRateRaw.decimalValue }
        set { compositeRateRaw = newValue as NSDecimalNumber; markModified() }
    }
}

// MARK: - Enum Wrappers

extension TreasuryPosition {
    var instrumentType: TreasuryInstrument {
        get { TreasuryInstrument(rawValue: instrumentTypeRaw) ?? .tBill }
        set { instrumentTypeRaw = newValue.rawValue; markModified() }
    }

    var couponFrequency: CouponFrequency {
        get { CouponFrequency(rawValue: couponFrequencyRaw) ?? .zero }
        set { couponFrequencyRaw = newValue.rawValue; markModified() }
    }
}

// MARK: - Computed

extension TreasuryPosition {
    var daysToMaturity: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: maturityDate).day ?? 0)
    }

    var isExpiredOrMatured: Bool {
        isMatured || maturityDate <= Date()
    }

    var discount: Decimal { faceValue - purchasePrice }

    var discountPercent: Decimal {
        guard faceValue > 0 else { return 0 }
        return ((faceValue - purchasePrice) / faceValue * 100).rounded(to: 2)
    }

    /// Effective principal used for TIPS coupon calculations.
    var effectivePrincipal: Decimal {
        inflationAdjustedPrincipal > 0 ? inflationAdjustedPrincipal : faceValue
    }

    /// Annual coupon payment amount.
    var annualCouponAmount: Decimal {
        (effectivePrincipal * couponRate).rounded(to: 2)
    }

    /// Per-payment coupon amount (based on frequency).
    var perPaymentCouponAmount: Decimal {
        let paymentsPerYear = couponFrequency.paymentsPerYear
        guard paymentsPerYear > 0 else { return 0 }
        return (annualCouponAmount / Decimal(paymentsPerYear)).rounded(to: 2)
    }

    /// I-Bond: true if still within the 1-year lockup.
    var isLocked: Bool {
        guard instrumentType == .iBond, let lockup = lockupExpiryDate else { return false }
        return Date() < lockup
    }

    /// I-Bond: true if still within 5-year penalty window (3-month interest forfeiture on redeem).
    var hasEarlyRedemptionPenalty: Bool {
        guard instrumentType == .iBond, let penaltyFree = penaltyFreeDate else { return false }
        return Date() < penaltyFree
    }

    /// TIPS phantom income this year: increase in inflation-adjusted principal.
    var tipsPhantomIncomeWarning: Bool {
        instrumentType == .tips && inflationAdjustedPrincipal > faceValue
    }
}

// MARK: - Factory

extension TreasuryPosition {
    static func create(
        in context: NSManagedObjectContext,
        holdingId: UUID,
        instrument: TreasuryInstrument,
        faceValue: Decimal,
        purchasePrice: Decimal,
        purchaseDate: Date,
        maturityDate: Date,
        couponRate: Decimal = 0,
        cusip: String? = nil,
        ibondFixedRate: Decimal = 0,
        ibondInflationRate: Decimal = 0
    ) -> TreasuryPosition {
        let pos = TreasuryPosition(context: context)
        pos.holdingId = holdingId
        pos.instrumentType = instrument
        pos.faceValue = faceValue
        pos.purchasePrice = purchasePrice
        pos.purchaseDate = purchaseDate
        pos.maturityDate = maturityDate
        pos.couponRate = couponRate
        pos.couponFrequency = CouponFrequency.for(instrument)
        pos.cusip = cusip.flatMap { $0.isEmpty ? nil : $0 }

        // Calculate YTM at purchase
        pos.ytmAtPurchase = TreasuryEngine.ytmAtPurchase(
            instrument: instrument,
            faceValue: faceValue,
            purchasePrice: purchasePrice,
            couponRate: couponRate,
            purchaseDate: purchaseDate,
            maturityDate: maturityDate
        )

        // I-Bond setup
        if instrument == .iBond {
            pos.fixedRate = ibondFixedRate
            pos.currentInflationRate = ibondInflationRate
            pos.compositeRate = TreasuryEngine.iBondCompositeRate(
                fixedRate: ibondFixedRate,
                semiannualCPI: ibondInflationRate
            )
            pos.ibondIssueDate = purchaseDate
            pos.lockupExpiryDate = Calendar.current.date(byAdding: .year, value: 1, to: purchaseDate)
            pos.penaltyFreeDate  = Calendar.current.date(byAdding: .year, value: 5, to: purchaseDate)
        }

        return pos
    }
}

// MARK: - Fetch Requests

extension TreasuryPosition {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<TreasuryPosition> {
        NSFetchRequest<TreasuryPosition>(entityName: "TreasuryPosition")
    }

    static func forHolding(_ holdingId: UUID) -> NSFetchRequest<TreasuryPosition> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        req.fetchLimit = 1
        return req
    }

    static func allUnmatured() -> NSFetchRequest<TreasuryPosition> {
        let req = fetchRequest()
        req.predicate = NSPredicate(format: "isMatured == NO")
        req.sortDescriptors = [NSSortDescriptor(keyPath: \TreasuryPosition.maturityDate, ascending: true)]
        return req
    }

    static func allPositions() -> NSFetchRequest<TreasuryPosition> {
        let req = fetchRequest()
        req.sortDescriptors = [NSSortDescriptor(keyPath: \TreasuryPosition.maturityDate, ascending: true)]
        return req
    }
}
