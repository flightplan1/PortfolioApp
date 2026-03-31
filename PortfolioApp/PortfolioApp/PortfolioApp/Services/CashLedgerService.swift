import Foundation
import CoreData

// MARK: - Cash Ledger Service
//
// Manages the canonical CASH holding used to track cash on hand.
// Each deposit or sale proceeds creates a new Lot (qty = dollar amount, costBasis = $1.00).
// Total cash balance = sum of all open CASH lot remainingQty values.

enum CashLedgerService {

    static let cashSymbol = "CASH"

    // MARK: - Find or Create

    /// Returns the canonical CASH holding, creating it if none exists.
    @discardableResult
    static func findOrCreateCashHolding(in context: NSManagedObjectContext) -> Holding {
        let req = Holding.fetchRequest()
        req.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            cashSymbol, AssetType.cash.rawValue
        )
        req.fetchLimit = 1
        if let existing = (try? context.fetch(req))?.first {
            return existing
        }
        let h = Holding(context: context)
        h.symbol       = cashSymbol
        h.name         = "Cash"
        h.assetTypeRaw = AssetType.cash.rawValue
        return h
    }

    // MARK: - Credit (sale proceeds or deposit)

    /// Add a cash lot for the given amount.
    /// Qty = dollar amount, costBasisPerShare = $1.00 → market value always equals face value.
    /// `sourceNote` is shown in the Cash position detail — e.g. "AAPL Sell", "Manual Deposit".
    static func credit(amount: Decimal,
                       date: Date,
                       sourceNote: String? = nil,
                       source: LotSource = .manual,
                       in context: NSManagedObjectContext) {
        guard amount > 0 else { return }
        let holding = findOrCreateCashHolding(in: context)
        let nextLotNumber = nextLot(for: holding.id, in: context)
        let lot = Lot.create(
            in: context,
            holdingId: holding.id,
            lotNumber: nextLotNumber,
            quantity: amount,
            costBasisPerShare: 1,
            purchaseDate: date,
            fee: 0,
            source: source
        )
        lot.sourceNote = sourceNote ?? "Manual Deposit"
    }

    // MARK: - Withdraw (manual cash withdrawal — debits lots AND records a Transaction)

    /// Withdraw cash: reduces lots FIFO and records a sell Transaction on the CASH holding
    /// so the withdrawal appears in the position's transaction history.
    static func withdraw(amount: Decimal,
                         date: Date,
                         in context: NSManagedObjectContext) {
        guard amount > 0 else { return }
        let holding = findOrCreateCashHolding(in: context)
        debit(amount: amount, in: context)

        // Record a transaction so the withdrawal shows in position history
        let tx = Transaction(context: context)
        tx.holdingId      = holding.id
        tx.lotId          = nil
        tx.type           = .sell
        tx.quantity       = amount
        tx.pricePerShare  = 1
        tx.totalAmount    = amount
        tx.fee            = 0
        tx.tradeDate      = date
        tx.settlementDate = date
        tx.notes          = "Manual Withdrawal"
    }

    // MARK: - Debit (internal — reduces lots FIFO, no transaction record)

    /// Reduce cash lots FIFO by the given amount. Does not go negative — stops when lots exhausted.
    /// Call `withdraw()` instead when you need a transaction record (manual withdrawals).
    static func debit(amount: Decimal, in context: NSManagedObjectContext) {
        guard amount > 0 else { return }
        let req = Holding.fetchRequest()
        req.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            cashSymbol, AssetType.cash.rawValue
        )
        req.fetchLimit = 1
        guard let holding = (try? context.fetch(req))?.first else { return }

        let lotsReq = Lot.openLots(for: holding.id)
        lotsReq.sortDescriptors = [NSSortDescriptor(keyPath: \Lot.purchaseDate, ascending: true)]
        let lots = (try? context.fetch(lotsReq)) ?? []

        var remaining = amount
        for lot in lots {
            guard remaining > 0 else { break }
            if lot.remainingQty <= remaining {
                remaining -= lot.remainingQty
                lot.remainingQty = 0
                lot.isClosed = true
            } else {
                lot.remainingQty = (lot.remainingQty - remaining).rounded(to: 8)
                remaining = 0
            }
        }
    }

    // MARK: - Balance Query

    /// Total available cash balance (sum of all open CASH lot remainingQty).
    static func availableBalance(in context: NSManagedObjectContext) -> Decimal {
        let req = Holding.fetchRequest()
        req.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            cashSymbol, AssetType.cash.rawValue
        )
        req.fetchLimit = 1
        guard let holding = (try? context.fetch(req))?.first else { return 0 }
        let lotsReq = Lot.openLots(for: holding.id)
        let lots = (try? context.fetch(lotsReq)) ?? []
        return lots.reduce(Decimal(0)) { $0 + $1.remainingQty }
    }

    // MARK: - Private Helpers

    private static func nextLot(for holdingId: UUID, in context: NSManagedObjectContext) -> Int32 {
        let req = Lot.fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        let count = (try? context.count(for: req)) ?? 0
        return Int32(count + 1)
    }
}
