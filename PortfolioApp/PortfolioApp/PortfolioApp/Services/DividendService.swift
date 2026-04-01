import Foundation
import CoreData

// MARK: - DividendService
// Handles dividend business logic:
//   - DRIP: auto-creates a Lot and a Transaction when user confirms reinvestment
//   - Projected annual income: extrapolates from lastDividendPerShare × openQty × frequency
//   - Yield: annualIncome / current market value

@MainActor
final class DividendService {

    static let shared = DividendService()
    private init() {}

    // MARK: - DRIP Lot Creation

    /// Records a DRIP dividend: creates the DividendEvent, a new Lot, and a buy Transaction.
    /// Returns the created DividendEvent and Lot so the caller can confirm/undo.
    @discardableResult
    func recordDRIP(
        holding: Holding,
        payDate: Date,
        exDividendDate: Date?,
        dividendPerShare: Decimal,
        sharesHeld: Decimal,
        reinvestedPricePerShare: Decimal,
        in context: NSManagedObjectContext
    ) throws -> (event: DividendEvent, lot: Lot) {
        let grossAmount      = (dividendPerShare * sharesHeld).rounded(to: 2)
        let reinvestedShares = reinvestedPricePerShare > 0
            ? (grossAmount / reinvestedPricePerShare).rounded(to: 6)
            : 0

        // Next lot number
        let existingLots = (try? context.fetch(Lot.openLots(for: holding.id))) ?? []
        let nextLotNumber = Int32((existingLots.map { Int($0.lotNumber) }.max() ?? 0) + 1)

        // Create the DRIP lot (purchase date = payDate per IRS — DRIP shares acquired on pay date)
        let lot = Lot.create(
            in: context,
            holdingId: holding.id,
            lotNumber: nextLotNumber,
            quantity: reinvestedShares,
            costBasisPerShare: reinvestedPricePerShare,
            purchaseDate: payDate,
            fee: 0,
            source: .drip
        )

        // Create corresponding buy transaction
        let tx = Transaction(context: context)
        tx.holdingId    = holding.id
        tx.lotId        = lot.id
        tx.type         = .drip
        tx.tradeDate    = payDate
        tx.quantity     = reinvestedShares
        tx.pricePerShare = reinvestedPricePerShare
        tx.totalAmount  = grossAmount
        tx.fee          = 0
        tx.notes        = "DRIP – \(holding.symbol)"

        // Create DividendEvent
        let event = DividendEvent.createDRIP(
            in: context,
            holdingId: holding.id,
            symbol: holding.symbol,
            payDate: payDate,
            exDividendDate: exDividendDate,
            dividendPerShare: dividendPerShare,
            sharesHeld: sharesHeld,
            reinvestedShares: reinvestedShares,
            reinvestedPricePerShare: reinvestedPricePerShare,
            linkedLotId: lot.id
        )
        lot.linkedDividendEventId = event.id

        // Update Holding's last dividend info
        holding.lastDividendPerShare = dividendPerShare
        if let exDiv = exDividendDate {
            holding.lastExDividendDate = exDiv
        }

        try context.save()
        return (event, lot)
    }

    /// Records a cash dividend (not reinvested).
    @discardableResult
    func recordCashDividend(
        holding: Holding,
        payDate: Date,
        exDividendDate: Date?,
        dividendPerShare: Decimal,
        sharesHeld: Decimal,
        in context: NSManagedObjectContext
    ) throws -> DividendEvent {
        let event = DividendEvent.createCash(
            in: context,
            holdingId: holding.id,
            symbol: holding.symbol,
            payDate: payDate,
            exDividendDate: exDividendDate,
            dividendPerShare: dividendPerShare,
            sharesHeld: sharesHeld
        )

        // Record as a dividend transaction on the holding
        let tx = Transaction(context: context)
        tx.holdingId    = holding.id
        tx.type         = .dividend
        tx.tradeDate    = payDate
        tx.quantity     = sharesHeld
        tx.pricePerShare = dividendPerShare
        tx.totalAmount  = event.grossAmount
        tx.fee          = 0
        tx.notes        = "Dividend – \(holding.symbol)"

        // Update Holding's last dividend info
        holding.lastDividendPerShare = dividendPerShare
        if let exDiv = exDividendDate {
            holding.lastExDividendDate = exDiv
        }

        try context.save()
        return event
    }

    // MARK: - Projected Annual Income

    /// Projects the annual dividend income for a holding based on:
    /// lastDividendPerShare × openQty × paymentsPerYear
    /// Returns nil if the holding has no dividend data or no open lots.
    func projectedAnnualIncome(
        holding: Holding,
        openQty: Decimal
    ) -> Decimal? {
        guard let dps = holding.lastDividendPerShare, dps > 0,
              openQty > 0 else { return nil }
        let freq = holding.dividendFrequency ?? .quarterly
        return (dps * openQty * Decimal(freq.paymentsPerYear)).rounded(to: 2)
    }

    /// Annual yield as a percentage: projectedAnnualIncome / marketValue × 100.
    /// Returns nil if price or dividend data is unavailable.
    func annualYieldPercent(
        holding: Holding,
        openQty: Decimal,
        currentPrice: Decimal
    ) -> Decimal? {
        guard currentPrice > 0,
              let income = projectedAnnualIncome(holding: holding, openQty: openQty) else { return nil }
        let marketValue = openQty * currentPrice
        guard marketValue > 0 else { return nil }
        return ((income / marketValue) * 100).rounded(to: 2)
    }

    // MARK: - Total Dividends Received (YTD)

    func totalDividendsYTD(events: [DividendEvent]) -> Decimal {
        let yearStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year], from: Date())
        ) ?? Date()
        return events
            .filter { $0.payDate >= yearStart }
            .reduce(0) { $0 + $1.grossAmount }
    }
}

// MARK: - DividendFrequency Extension

extension DividendFrequency {
    var paymentsPerYear: Int {
        switch self {
        case .monthly:    return 12
        case .quarterly:  return 4
        case .semiAnnual: return 2
        case .annual:     return 1
        case .irregular:  return 1
        }
    }
}
