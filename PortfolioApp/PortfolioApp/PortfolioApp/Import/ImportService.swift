import Foundation
import CoreData
import Combine

// MARK: - Import Service
// Orchestrates parse → validate → conflict detection → atomic CoreData execution → 60s undo.

@MainActor
final class ImportService: ObservableObject {

    @Published private(set) var isExecuting = false
    @Published private(set) var undoSecondsRemaining: Int = 0
    @Published private(set) var lastResult: ImportResult?

    private var undoObjects: [NSManagedObject] = []
    private var undoTimer: Timer?

    // MARK: - Parse

    func parse(url: URL) throws -> (parseResult: ImportParseResult, csvMapping: CSVColumnMapping?) {
        guard let format = ImportFormat.detect(from: url) else {
            throw ImportError.unsupportedFormat(url.pathExtension.uppercased())
        }
        switch format {
        case .csv:
            let (mapping, result) = try CSVParser.parse(url: url)
            return (result, mapping)
        case .json:
            return (try JSONImporter.parse(url: url), nil)
        case .xlsx:
            throw ImportError.unsupportedFormat("XLSX — export as CSV and re-import.")
        }
    }

    // MARK: - Conflict Detection

    func detectConflicts(
        symbols: Set<String>,
        incomingCounts: [String: Int],
        context: NSManagedObjectContext
    ) -> [ImportConflict] {
        symbols.compactMap { symbol in
            let req = Holding.fetchRequest()
            req.predicate = NSPredicate(format: "symbol == %@", symbol)
            req.fetchLimit = 1
            guard let holding = (try? context.fetch(req))?.first else { return nil }

            let lotCount = (try? context.fetch(Lot.openLots(for: holding.id)))?.count ?? 0
            guard lotCount > 0 else { return nil }

            return ImportConflict(
                symbol: symbol,
                existingLotCount: lotCount,
                incomingTransactionCount: incomingCounts[symbol] ?? 0
            )
        }.sorted { $0.symbol < $1.symbol }
    }

    // MARK: - Execute

    func execute(
        parseResult: ImportParseResult,
        resolution: ImportConflictResolution,
        fileName: String,
        context: NSManagedObjectContext
    ) async throws -> ImportResult {
        isExecuting = true
        defer { isExecuting = false }

        let sessionId = UUID()
        var createdObjects: [NSManagedObject] = []
        var holdingsCreated = 0
        var holdingsUpdated = 0
        var lotsCreated = 0

        // Sort chronologically so FIFO logic on sells is correct
        let sorted = parseResult.transactions.sorted { $0.tradeDate < $1.tradeDate }

        // Cache symbol+assetType → Holding to avoid repeated fetches
        var holdingCache: [String: Holding] = [:]

        // Replace resolution: soft-delete all open lots for imported symbols
        if resolution == .replace {
            for symbol in parseResult.uniqueSymbols {
                let req = Holding.fetchRequest()
                req.predicate = NSPredicate(format: "symbol == %@", symbol)
                guard let holding = (try? context.fetch(req))?.first else { continue }
                let lots = (try? context.fetch(Lot.openLots(for: holding.id))) ?? []
                for lot in lots { lot.softDelete(reason: .importRollback) }
            }
        }

        for tx in sorted {
            switch tx.action {

            // MARK: Buy / Transfer In
            case .buy, .transferIn:
                let holding = try findOrCreate(tx: tx, cache: &holdingCache,
                                              context: context,
                                              created: &holdingsCreated,
                                              updated: &holdingsUpdated)
                if holding.objectID.isTemporaryID { createdObjects.append(holding) }

                let lotNo = nextLotNumber(for: holding.id, context: context)
                let lot = Lot.create(
                    in: context,
                    holdingId: holding.id,
                    lotNumber: lotNo,
                    quantity: tx.quantity,
                    costBasisPerShare: tx.pricePerShare,
                    purchaseDate: tx.tradeDate,
                    fee: tx.fee,
                    source: .import
                )
                createdObjects.append(lot)

                let txRecord = Transaction.createBuy(
                    in: context,
                    holdingId: holding.id,
                    lotId: lot.id,
                    quantity: tx.quantity,
                    pricePerShare: tx.pricePerShare,
                    fee: tx.fee,
                    tradeDate: tx.tradeDate
                )
                txRecord.importSessionId = sessionId
                txRecord.notes = tx.notes
                createdObjects.append(txRecord)
                lotsCreated += 1

            // MARK: Sell
            case .sell:
                guard let holding = find(symbol: tx.symbol, cache: holdingCache, context: context) else { continue }

                // FIFO: consume oldest lots first
                let openLots = (try? context.fetch(Lot.openLots(for: holding.id))) ?? []
                var remaining = tx.quantity

                for lot in openLots where remaining > 0 {
                    let sellQty = min(lot.remainingQty, remaining)
                    lot.remainingQty -= sellQty
                    if lot.remainingQty <= 0 {
                        lot.isClosed = true
                        lot.remainingQty = 0
                    }
                    remaining -= sellQty

                    // Apportion fee proportionally across lots
                    let lotFee = tx.quantity > 0 ? (tx.fee * sellQty / tx.quantity).rounded(to: 4) : 0
                    let sellTx = Transaction.createSell(
                        in: context,
                        holdingId: holding.id,
                        lotId: lot.id,
                        quantity: sellQty,
                        pricePerShare: tx.pricePerShare,
                        fee: lotFee,
                        tradeDate: tx.tradeDate
                    )
                    sellTx.importSessionId = sessionId
                    createdObjects.append(sellTx)
                }

            // MARK: Dividend
            case .dividend:
                guard let holding = find(symbol: tx.symbol, cache: holdingCache, context: context) else { continue }
                let divTx = Transaction(context: context)
                divTx.holdingId = holding.id
                divTx.type = .dividend
                divTx.tradeDate = tx.tradeDate
                divTx.quantity = tx.quantity
                divTx.pricePerShare = tx.pricePerShare
                divTx.totalAmount = tx.effectiveCostBasis
                divTx.fee = tx.fee
                divTx.importSessionId = sessionId
                divTx.notes = tx.notes
                createdObjects.append(divTx)

            // MARK: DRIP
            case .drip:
                guard let holding = find(symbol: tx.symbol, cache: holdingCache, context: context) else { continue }
                if tx.quantity > 0 {
                    let lotNo = nextLotNumber(for: holding.id, context: context)
                    let lot = Lot.create(
                        in: context,
                        holdingId: holding.id,
                        lotNumber: lotNo,
                        quantity: tx.quantity,
                        costBasisPerShare: tx.pricePerShare,
                        purchaseDate: tx.tradeDate,
                        source: .drip
                    )
                    createdObjects.append(lot)
                    lotsCreated += 1

                    let dripTx = Transaction(context: context)
                    dripTx.holdingId = holding.id
                    dripTx.lotId = lot.id
                    dripTx.type = .drip
                    dripTx.tradeDate = tx.tradeDate
                    dripTx.quantity = tx.quantity
                    dripTx.pricePerShare = tx.pricePerShare
                    dripTx.totalAmount = (tx.quantity * tx.pricePerShare).rounded(to: 2)
                    dripTx.importSessionId = sessionId
                    createdObjects.append(dripTx)
                }

            // MARK: Split
            case .split:
                guard let holding = find(symbol: tx.symbol, cache: holdingCache, context: context),
                      let ratio = tx.splitRatio else { continue }
                let openLots = (try? context.fetch(Lot.openLots(for: holding.id))) ?? []
                for lot in openLots {
                    lot.splitAdjustedQty = (lot.splitAdjustedQty * ratio.multiplier).rounded(to: 4)
                    lot.splitAdjustedCostBasisPerShare = (lot.splitAdjustedCostBasisPerShare / ratio.multiplier).rounded(to: 6)
                    lot.remainingQty = (lot.remainingQty * ratio.multiplier).rounded(to: 4)
                }
                let splitTx = Transaction(context: context)
                splitTx.holdingId = holding.id
                splitTx.type = .split
                splitTx.tradeDate = tx.tradeDate
                splitTx.notes = ratio.displayString
                splitTx.importSessionId = sessionId
                createdObjects.append(splitTx)

            // MARK: Transfer Out
            case .transferOut:
                guard let holding = find(symbol: tx.symbol, cache: holdingCache, context: context) else { continue }
                let outTx = Transaction(context: context)
                outTx.holdingId = holding.id
                outTx.type = .transferOut
                outTx.tradeDate = tx.tradeDate
                outTx.quantity = tx.quantity
                outTx.pricePerShare = tx.pricePerShare
                outTx.totalAmount = tx.effectiveCostBasis
                outTx.importSessionId = sessionId
                outTx.notes = tx.notes
                createdObjects.append(outTx)
            }
        }

        // Atomic save
        do {
            try context.save()
        } catch {
            context.rollback()
            throw ImportError.executionFailed(error.localizedDescription)
        }

        // After save, objectIDs are permanent — store for undo
        undoObjects = createdObjects
        startUndoTimer()

        let result = ImportResult(
            sessionId: sessionId,
            importedAt: Date(),
            fileName: fileName,
            transactionsImported: sorted.count,
            holdingsCreated: holdingsCreated,
            holdingsUpdated: holdingsUpdated,
            lotsCreated: lotsCreated,
            warnings: parseResult.warnings
        )
        lastResult = result
        return result
    }

    // MARK: - Undo

    func undo(context: NSManagedObjectContext) {
        for obj in undoObjects {
            if !obj.isDeleted { context.delete(obj) }
        }
        try? context.save()
        clearUndo()
    }

    // MARK: - Undo Timer

    private func startUndoTimer() {
        undoSecondsRemaining = 60
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.undoSecondsRemaining -= 1
                if self.undoSecondsRemaining <= 0 {
                    self.clearUndo()
                }
            }
        }
    }

    private func clearUndo() {
        undoTimer?.invalidate()
        undoTimer = nil
        undoSecondsRemaining = 0
        undoObjects = []
        if var r = lastResult {
            r.canUndo = false
            lastResult = r
        }
    }

    // MARK: - CoreData Helpers

    private func findOrCreate(
        tx: ImportedTransaction,
        cache: inout [String: Holding],
        context: NSManagedObjectContext,
        created: inout Int,
        updated: inout Int
    ) throws -> Holding {
        let key = "\(tx.symbol)-\(tx.effectiveAssetType.rawValue)"
        if let cached = cache[key] { updated += 1; return cached }

        let req = Holding.fetchRequest()
        req.predicate = NSPredicate(format: "symbol == %@ AND assetTypeRaw == %@",
                                    tx.symbol, tx.effectiveAssetType.rawValue)
        req.fetchLimit = 1

        if let existing = (try? context.fetch(req))?.first {
            if let s = tx.sector, !s.isEmpty, existing.sector == nil { existing.sector = s }
            cache[key] = existing
            updated += 1
            return existing
        }

        let holding = Holding(context: context)
        holding.symbol = tx.symbol
        holding.assetType = tx.effectiveAssetType
        holding.name = tx.symbol    // PriceService will fill in the real name later
        if let s = tx.sector, !s.isEmpty { holding.sector = s }
        cache[key] = holding
        created += 1
        return holding
    }

    private func find(symbol: String, cache: [String: Holding], context: NSManagedObjectContext) -> Holding? {
        for type in AssetType.allCases {
            if let h = cache["\(symbol)-\(type.rawValue)"] { return h }
        }
        let req = Holding.fetchRequest()
        req.predicate = NSPredicate(format: "symbol == %@", symbol)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    private func nextLotNumber(for holdingId: UUID, context: NSManagedObjectContext) -> Int32 {
        let req = Lot.fetchRequest()
        req.predicate = NSPredicate(format: "holdingId == %@", holdingId as CVarArg)
        req.sortDescriptors = [NSSortDescriptor(keyPath: \Lot.lotNumber, ascending: false)]
        req.fetchLimit = 1
        return ((try? context.fetch(req))?.first?.lotNumber ?? 0) + 1
    }
}
