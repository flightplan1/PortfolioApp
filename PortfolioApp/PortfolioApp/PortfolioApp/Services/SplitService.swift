import Foundation
import CoreData
import Combine

// MARK: - Pending Split
// Returned by detectSplits() for each unprocessed split found on Finnhub.
// Presented to the user via SplitConfirmationView before applying.

struct PendingSplit: Identifiable {
    let id = UUID()
    let holding: Holding
    let numerator: Int
    let denominator: Int
    let splitDate: Date
    let isForward: Bool

    var ratioString: String { "\(numerator):\(denominator)" }
    var multiplier: Decimal { Decimal(numerator) / Decimal(denominator) }
}

// MARK: - SplitService
// Handles all split lifecycle:
//   - detectSplits(): polls Finnhub /stock/split for each holding (daily check)
//   - applySplit(): atomically adjusts all lots, creates SplitEvent + SplitSnapshot
//   - revertSplit(): restores lot state from SplitSnapshot (within 24 hours)
//   - addManualSplit(): user-entered historical split

final class SplitService: ObservableObject {

    static let shared = SplitService()
    private init() {}

    /// Splits awaiting user confirmation.
    @Published private(set) var pendingSplits: [PendingSplit] = []

    private let lastCheckKey = "splitService.lastCheckDate"

    // MARK: - Detection

    /// Checks Finnhub for recent splits on all stock/ETF holdings.
    /// Skips if already checked today. Call on app launch / foreground.
    func detectSplitsIfNeeded(holdings: [Holding], context: NSManagedObjectContext) async {
        let today = Calendar.current.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Calendar.current.startOfDay(for: last) == today { return }
        await detectSplits(holdings: holdings, context: context)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
    }

    func detectSplits(holdings: [Holding], context: NSManagedObjectContext) async {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return }

        // Only stock/ETF holdings can have traditional splits
        let eligible = holdings.filter { $0.assetType == .stock || $0.assetType == .etf }

        // Fetch already-applied splits so we don't re-prompt
        let appliedEventIds = appliedSplitKeys(in: context)

        var detected: [PendingSplit] = []

        for holding in eligible {
            guard let splits = await fetchFinnhubSplits(symbol: holding.symbol, apiKey: apiKey) else { continue }
            for split in splits {
                let key = "\(holding.symbol)_\(split.date)"
                guard !appliedEventIds.contains(key) else { continue }
                guard let pending = makePendingSplit(holding: holding, finnhubSplit: split) else { continue }
                detected.append(pending)
            }
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms — stay within Finnhub rate limit
        }

        if !detected.isEmpty {
            await MainActor.run { pendingSplits = detected }
        }
    }

    // MARK: - Apply

    /// Atomically adjusts all open lots for a split. Creates SplitEvent + SplitSnapshot.
    /// The snapshot allows reverting within 24 hours.
    @MainActor @discardableResult
    func applySplit(_ pending: PendingSplit, in context: NSManagedObjectContext) throws -> SplitEvent {
        let lots = (try? context.fetch(Lot.openLots(for: pending.holding.id))) ?? []
        _ = lots
        let allLotsReq = Lot.fetchRequest()
        allLotsReq.predicate = NSPredicate(format: "holdingId == %@ AND isSoftDeleted == NO", pending.holding.id as CVarArg)
        let allLotsIncludingClosed = (try? context.fetch(allLotsReq)) ?? []

        let multiplier = pending.multiplier

        // Snapshot BEFORE adjustment
        let splitEvent = SplitEvent.create(
            in: context,
            holdingId: pending.holding.id,
            symbol: pending.holding.symbol,
            splitDate: pending.splitDate,
            numerator: pending.numerator,
            denominator: pending.denominator,
            entryMethod: .auto
        )

        // Record before-shares
        let beforeShares = allLotsIncludingClosed.reduce(Decimal(0)) { $0 + $1.splitAdjustedQty }
        splitEvent.snapshotBeforeShares = beforeShares

        // Save snapshot for revert
        let snapshot = SplitSnapshot.create(in: context, splitEventId: splitEvent.id, lots: allLotsIncludingClosed)
        _ = snapshot

        // Apply adjustment to all lots atomically
        for lot in allLotsIncludingClosed {
            lot.splitAdjustedQty = (lot.splitAdjustedQty * multiplier).rounded(to: 6)
            lot.splitAdjustedCostBasisPerShare = (lot.splitAdjustedCostBasisPerShare / multiplier).rounded(to: 6)
            // remainingQty tracks open quantity — also needs adjustment
            if !lot.isClosed {
                lot.remainingQty = (lot.remainingQty * multiplier).rounded(to: 6)
            }
            // Append this split to the lot's history
            var history = lot.splitHistory
            history.append(splitEvent.id)
            lot.splitHistory = history
        }

        // Record after-shares
        let afterShares = allLotsIncludingClosed.reduce(Decimal(0)) { $0 + $1.splitAdjustedQty }
        splitEvent.snapshotAfterShares = afterShares
        splitEvent.appliedAt = Date()

        // Mark options on this stock with OCC warning via splitHistory on their lots
        // (Options are not adjusted — their lots get the splitEventId in splitHistory
        //  so LotRowView can show the OCC banner.)
        let optionReq = Holding.fetchRequest()
        optionReq.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            pending.holding.symbol, AssetType.options.rawValue
        )
        let optionHoldings = (try? context.fetch(optionReq)) ?? []
        for optionHolding in optionHoldings {
            let optionLots = (try? context.fetch(Lot.openLots(for: optionHolding.id))) ?? []
            for lot in optionLots {
                var history = lot.splitHistory
                history.append(splitEvent.id)
                lot.splitHistory = history
            }
        }

        try context.save()

        // Remove from pending
        pendingSplits.removeAll { $0.id == pending.id }

        return splitEvent
    }

    // MARK: - Revert

    /// Restores lot state from SplitSnapshot. Only available within 24 hours.
    @MainActor func revertSplit(_ splitEvent: SplitEvent, in context: NSManagedObjectContext) throws {
        guard let snapshot = (try? context.fetch(SplitSnapshot.forSplitEvent(splitEvent.id)))?.first else {
            throw SplitError.snapshotNotFound
        }
        guard snapshot.isStillRevertable else {
            throw SplitError.revertWindowExpired
        }

        let allLotsReq = Lot.fetchRequest()
        allLotsReq.predicate = NSPredicate(format: "holdingId == %@ AND isSoftDeleted == NO", splitEvent.holdingId as CVarArg)
        let allLots = (try? context.fetch(allLotsReq)) ?? []

        let lotMap = Dictionary(allLots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for snap in snapshot.lotSnapshots {
            guard let lot = lotMap[snap.lotId] else { continue }
            lot.splitAdjustedQty = snap.splitAdjustedQty
            lot.splitAdjustedCostBasisPerShare = snap.splitAdjustedCostBasisPerShare
            lot.remainingQty = snap.remainingQty
            lot.splitHistoryData = snap.splitHistoryData
        }

        // Also revert any option lots that were tagged
        let revertOptionReq = Holding.fetchRequest()
        revertOptionReq.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            splitEvent.symbol, AssetType.options.rawValue
        )
        let optionHoldings = (try? context.fetch(revertOptionReq)) ?? []
        for optionHolding in optionHoldings {
            let optionLots = (try? context.fetch(Lot.openLots(for: optionHolding.id))) ?? []
            for lot in optionLots {
                lot.splitHistory = lot.splitHistory.filter { $0 != splitEvent.id }
            }
        }

        context.delete(snapshot)
        context.delete(splitEvent)
        try context.save()
    }

    // MARK: - Manual Entry

    /// Records a historical split entered by the user (pre-app splits).
    @MainActor @discardableResult
    func addManualSplit(
        holding: Holding,
        splitDate: Date,
        numerator: Int,
        denominator: Int,
        in context: NSManagedObjectContext
    ) throws -> SplitEvent {
        let pending = PendingSplit(
            holding: holding,
            numerator: numerator,
            denominator: denominator,
            splitDate: splitDate,
            isForward: numerator >= denominator
        )
        let event = try applySplit(pending, in: context)
        event.entryMethod = .manual
        try context.save()
        return event
    }

    // MARK: - Dismiss

    @MainActor func dismissPendingSplit(_ pending: PendingSplit) {
        pendingSplits.removeAll { $0.id == pending.id }
        // Remember we skipped it so we don't re-prompt today
        let key = "\(pending.holding.symbol)_\(pending.splitDate.ISO8601Format())"
        var skipped = UserDefaults.standard.stringArray(forKey: "splitService.skipped") ?? []
        skipped.append(key)
        UserDefaults.standard.set(skipped, forKey: "splitService.skipped")
    }

    // MARK: - Private Helpers

    private func appliedSplitKeys(in context: NSManagedObjectContext) -> Set<String> {
        let events = (try? context.fetch(SplitEvent.all())) ?? []
        let skipped = Set(UserDefaults.standard.stringArray(forKey: "splitService.skipped") ?? [])
        let applied = Set(events.map { "\($0.symbol)_\($0.splitDate.ISO8601Format())" })
        return applied.union(skipped)
    }

    private struct FinnhubSplit: Decodable {
        let date: String
        let fromFactor: Decimal
        let toFactor: Decimal

        // Finnhub encodes splits as fromFactor:toFactor
        // 2:1 forward split → fromFactor=2, toFactor=1
    }

    private func fetchFinnhubSplits(symbol: String, apiKey: String) async -> [FinnhubSplit]? {
        // Check 1 year back for recent splits
        let from = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .year, value: -1, to: Date())!)
        let to   = ISO8601DateFormatter().string(from: Date())
        let urlStr = "https://finnhub.io/api/v1/stock/split?symbol=\(symbol)&from=\(String(from.prefix(10)))&to=\(String(to.prefix(10)))&token=\(apiKey)"
        guard let url = URL(string: urlStr) else { return nil }

        struct Response: Decodable { let data: [FinnhubSplit]? }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(Response.self, from: data)
            return response.data
        } catch {
            return nil
        }
    }

    private func makePendingSplit(holding: Holding, finnhubSplit: FinnhubSplit) -> PendingSplit? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        guard let date = formatter.date(from: finnhubSplit.date) else { return nil }
        guard finnhubSplit.fromFactor > 0, finnhubSplit.toFactor > 0 else { return nil }

        // Convert to integer ratio
        // Finnhub: fromFactor=2, toFactor=1 means 2 new shares for every 1 old → 2:1 forward split
        let num = Int(exactly: NSDecimalNumber(decimal: finnhubSplit.fromFactor)) ?? 0
        let den = Int(exactly: NSDecimalNumber(decimal: finnhubSplit.toFactor))  ?? 0
        guard num > 0, den > 0 else { return nil }

        return PendingSplit(
            holding: holding,
            numerator: num,
            denominator: den,
            splitDate: date,
            isForward: finnhubSplit.fromFactor >= finnhubSplit.toFactor
        )
    }
}

// MARK: - Errors

enum SplitError: LocalizedError {
    case snapshotNotFound
    case revertWindowExpired

    var errorDescription: String? {
        switch self {
        case .snapshotNotFound:     return "Split snapshot not found. Cannot revert."
        case .revertWindowExpired:  return "The 24-hour revert window has expired."
        }
    }
}
