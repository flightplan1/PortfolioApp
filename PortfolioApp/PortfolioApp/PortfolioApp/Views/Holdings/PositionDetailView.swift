import SwiftUI
import CoreData

struct PositionDetailView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var priceService:      PriceService
    @EnvironmentObject private var taxProfileManager: TaxProfileManager

    @FetchRequest private var lots: FetchedResults<Lot>
    @FetchRequest private var closedLots: FetchedResults<Lot>
    @FetchRequest private var transactions: FetchedResults<Transaction>
    @FetchRequest private var dividendEvents: FetchedResults<DividendEvent>
    @FetchRequest private var splitEvents: FetchedResults<SplitEvent>

    @State private var showAddLot          = false
    @State private var showSellPosition    = false
    @State private var showDepositCash     = false
    @State private var showWithdrawCash    = false
    @State private var showAddDividend     = false
    @State private var showAddSplit        = false
    @State private var showPriceAlerts     = false
    @State private var lotsCollapsed          = true
    @State private var transactionsCollapsed  = true
    @State private var closedLotsCollapsed    = true
    @State private var dividendsCollapsed     = true
    @State private var splitsCollapsed        = true
    @State private var lotToEdit:   Lot?
    @State private var lotToSell:   Lot?
    @State private var lotToDelete: Lot?
    @State private var cashLotToEdit: Lot?
    @State private var showResetCashConfirm = false
    @State private var showEditHolding = false
    @State private var splitToRevert: SplitEvent?
    @State private var showRevertAlert = false
    @State private var revertAlertMessage = ""
    @State private var noteDraft: String = ""
    @State private var isEditingNote: Bool = false
    @State private var transactionToEdit: Transaction?

    // MARK: - Undo Toast
    @State private var undoToastVisible  = false
    @State private var undoToastMessage  = ""
    @State private var undoTransaction:  Transaction?
    @State private var undoLotSnapshot:  (id: UUID, remainingQty: Decimal, isClosed: Bool)?
    @State private var undoWorkItem:     DispatchWorkItem?

    init(holding: Holding) {
        self.holding = holding
        _lots = FetchRequest(fetchRequest: Lot.openLots(for: holding.id), animation: .default)
        _closedLots = FetchRequest(fetchRequest: Lot.closedLots(for: holding.id), animation: .default)
        _transactions = FetchRequest(fetchRequest: Transaction.activeTransactions(for: holding.id), animation: .default)
        _dividendEvents = FetchRequest(fetchRequest: DividendEvent.forHolding(holding.id), animation: .default)
        _splitEvents = FetchRequest(fetchRequest: SplitEvent.forHolding(holding.id), animation: .default)
    }

    // MARK: - Computed

    private var openLots: [Lot] { Array(lots) }

    struct ClosedLotData {
        let proceeds: Decimal
        let gain: Decimal
        let saleDate: Date        // latest sell date for this lot
        let isLongTermAtSale: Bool
    }

    /// Realized data per closed lot, keyed by lot.id.
    /// Proceeds = sum of sell tx.totalAmount for that lot.
    /// Gain = (proceeds − lot.totalCostBasis) × pnlDirection.
    /// isLongTermAtSale = whether the latest sell date was >366 days after purchase.
    private var closedLotDataMap: [UUID: ClosedLotData] {
        let dir = holding.pnlDirection
        let sellTxs = transactions.filter { $0.type == .sell }

        // Pass 1: match sells that have a lotId
        var proceedsMap: [UUID: Decimal] = [:]
        var saleDateMap: [UUID: Date]    = [:]
        var unlinkedProceeds: Decimal    = 0
        var unlinkedLatestDate: Date?    = nil

        for tx in sellTxs {
            if let lotId = tx.lotId {
                proceedsMap[lotId, default: 0] += tx.totalAmount
                if let prev = saleDateMap[lotId] {
                    saleDateMap[lotId] = max(prev, tx.tradeDate)
                } else {
                    saleDateMap[lotId] = tx.tradeDate
                }
            } else {
                // No lotId — pool for fallback distribution
                unlinkedProceeds += tx.totalAmount
                if let prev = unlinkedLatestDate {
                    unlinkedLatestDate = max(prev, tx.tradeDate)
                } else {
                    unlinkedLatestDate = tx.tradeDate
                }
            }
        }

        // Pass 2: match unlinked sells to unmatched closed lots by quantity (FIFO by purchase date)
        // This handles the common case where a sell covers exactly one lot's originalQty.
        if unlinkedProceeds > 0 {
            var unmatchedLots = closedLots
                .filter { proceedsMap[$0.id] == nil }
                .sorted { $0.purchaseDate < $1.purchaseDate }   // FIFO order

            var remainingUnlinked = unlinkedProceeds
            let remainingDate = unlinkedLatestDate

            // Group unlinked sells by quantity for exact-match attempt
            let unlinkedSells = sellTxs.filter { $0.lotId == nil }
                .sorted { $0.tradeDate < $1.tradeDate }

            for tx in unlinkedSells {
                // Try to find an unmatched lot whose originalQty matches this sell's quantity
                if let idx = unmatchedLots.firstIndex(where: {
                    ($0.originalQty - tx.quantity).magnitude < Decimal(string: "0.0001")!
                }) {
                    let lot = unmatchedLots[idx]
                    proceedsMap[lot.id, default: 0] += tx.totalAmount
                    saleDateMap[lot.id] = saleDateMap[lot.id].map { max($0, tx.tradeDate) } ?? tx.tradeDate
                    unmatchedLots.remove(at: idx)
                    remainingUnlinked -= tx.totalAmount
                }
                // sells that don't qty-match any lot stay in remainingUnlinked
            }

            // Pass 3: for any still-unmatched lots, distribute remaining proceeds proportionally
            if remainingUnlinked > 0 && !unmatchedLots.isEmpty {
                let totalUnmatchedQty = unmatchedLots.reduce(Decimal(0)) { $0 + $1.originalQty }
                if totalUnmatchedQty > 0 {
                    for lot in unmatchedLots {
                        let share = (lot.originalQty / totalUnmatchedQty * remainingUnlinked).rounded(to: 2)
                        proceedsMap[lot.id, default: 0] += share
                        saleDateMap[lot.id] = remainingDate ?? lot.purchaseDate
                    }
                }
            }
        }

        var result: [UUID: ClosedLotData] = [:]
        for lot in closedLots {
            guard let proceeds = proceedsMap[lot.id],
                  let saleDate = saleDateMap[lot.id] else { continue }
            let ltThreshold = Calendar.current.date(byAdding: .day, value: 366, to: lot.purchaseDate)!
            let isLT = saleDate > ltThreshold
            // Use per-share basis × qty × multiplier (robust against stored totalCostBasis being wrong)
            let lotBasis = (lot.splitAdjustedCostBasisPerShare * lot.originalQty * holding.lotMultiplier)
                .rounded(to: 2)
            let gain = (proceeds - lotBasis) * dir
            result[lot.id] = ClosedLotData(
                proceeds: proceeds,
                gain: gain,
                saleDate: saleDate,
                isLongTermAtSale: isLT
            )
        }
        return result
    }

    private var totalQty: Decimal {
        openLots.reduce(0) { $0 + $1.remainingQty }
    }

    /// Total cost basis computed from per-share basis × qty × multiplier.
    /// Uses splitAdjustedCostBasisPerShare rather than the stored totalCostBasis field,
    /// which may be incorrect for options lots created without the ×100 multiplier.
    private var totalCostBasis: Decimal {
        openLots.reduce(Decimal(0)) { sum, lot in
            (sum + lot.splitAdjustedCostBasisPerShare * lot.remainingQty * holding.lotMultiplier)
                .rounded(to: 2)
        }
    }

    /// Weighted average premium/price per share across all open lots.
    /// For options this is the premium per share (not per contract).
    private var avgCostPerShare: Decimal {
        guard totalQty > 0 else { return 0 }
        return (openLots.reduce(Decimal(0)) { sum, lot in
            sum + lot.splitAdjustedCostBasisPerShare * lot.remainingQty
        } / totalQty).rounded(to: 4)
    }

    private var priceData: PriceData? {
        // Options: symbol is the underlying (e.g. "ANET"), not an option contract.
        // Showing the stock price as option price/P&L is misleading — suppress it.
        guard !holding.isOption else { return nil }
        return priceService.price(for: holding.symbol)
    }

    private var currentPrice: Decimal? { priceData?.currentPrice }

    /// For options: current price of the underlying stock (used for % to strike).
    private var underlyingPrice: Decimal? {
        guard holding.isOption else { return nil }
        return priceService.currentPrice(for: holding.symbol)
    }

    /// % distance from current underlying price to strike price.
    /// Positive = underlying is above strike; negative = below.
    private var percentToStrike: Decimal? {
        guard let underlying = underlyingPrice,
              let strike = holding.strikePrice, strike > 0 else { return nil }
        return ((underlying - strike) / strike * 100).rounded(to: 2)
    }

    /// Current market value of the position.
    /// Options: current option price × contracts × 100 (cost-to-close for STO, proceeds-if-closed for BTO).
    private var marketValue: Decimal? {
        guard let price = currentPrice else { return nil }
        return openLots.reduce(Decimal(0)) { sum, lot in
            sum + lot.marketValue(at: price, multiplier: holding.lotMultiplier)
        }
    }

    /// Unrealized P&L — sign-corrected for short options (STO profits when option declines).
    private var unrealizedPnL: Decimal? {
        guard let price = currentPrice else { return nil }
        return openLots.reduce(Decimal(0)) { sum, lot in
            sum + lot.unrealizedPnL(at: price, multiplier: holding.lotMultiplier) * holding.pnlDirection
        }
    }

    private var unrealizedPnLPercent: Decimal? {
        guard let pnl = unrealizedPnL, totalCostBasis > 0 else { return nil }
        return ((pnl / totalCostBasis) * 100).rounded(to: 2)
    }

    private var dividendYieldPercent: Decimal? {
        guard let price = currentPrice else { return nil }
        return DividendService.shared.annualYieldPercent(
            holding: holding,
            openQty: totalQty,
            currentPrice: price
        )
    }

    private var dividendYTD: Decimal {
        DividendService.shared.totalDividendsYTD(events: Array(dividendEvents))
    }

    /// Computes a tax estimate for selling a lot at the current price.
    private func lotTaxEstimate(for lot: Lot) -> TaxEstimate? {
        guard !holding.isRetirementAccount,
              taxProfileManager.isProfileComplete,
              let price = currentPrice else { return nil }
        let m    = holding.lotMultiplier
        let dir  = holding.pnlDirection
        let gain = (lot.unrealizedPnL(at: price, multiplier: m) * dir).rounded(to: 2)
        guard gain > 0 else { return nil }
        let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
        return engine.estimate(
            gain: gain,
            purchaseDate: lot.purchaseDate,
            saleDate: Date(),
            isSection1256: holding.isSection1256
        )
    }

    /// Estimated tax saving if the lot is held to LT qualification (ST tax − LT tax).
    /// Returns nil when lot is already LT, has no unrealized gain, or profile is incomplete.
    private func lotLTSaving(for lot: Lot) -> Decimal? {
        guard !holding.isRetirementAccount,
              !lot.isLongTerm,
              let days = lot.daysToLongTerm,
              days <= 60,
              taxProfileManager.isProfileComplete,
              let price = currentPrice else { return nil }
        let m    = holding.lotMultiplier
        let dir  = holding.pnlDirection
        let gain = (lot.unrealizedPnL(at: price, multiplier: m) * dir).rounded(to: 2)
        guard gain > 0 else { return nil }
        let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
        let ltDate = lot.longTermQualifyingDate ?? Date().addingTimeInterval(Double(days) * 86400)
        let stEst  = engine.estimate(gain: gain, purchaseDate: lot.purchaseDate, saleDate: Date(),   isSection1256: holding.isSection1256)
        let ltEst  = engine.estimate(gain: gain, purchaseDate: lot.purchaseDate, saleDate: ltDate,  isSection1256: holding.isSection1256)
        let saving = stEst.totalTax - ltEst.totalTax
        return saving > 0 ? saving : nil
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var trailingToolbarButtons: some View {
        HStack(spacing: 4) {
            if holding.assetType == .cash {
                Button { showEditHolding = true } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.textSub)
                }
                Button { showWithdrawCash = true } label: {
                    Text("Withdraw")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.appRed)
                }
                Button { showDepositCash = true } label: {
                    Text("Deposit")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.appBlue)
                }
            } else {
                if !openLots.isEmpty {
                    Button { showSellPosition = true } label: {
                        Text("Sell")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.appRed)
                    }
                }
                if holding.assetType == .stock || holding.assetType == .etf || holding.assetType == .crypto {
                    Button { showAddDividend = true } label: {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.appGold)
                    }
                }
                if holding.assetType == .stock || holding.assetType == .etf {
                    Button { showAddSplit = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.appBlue.opacity(0.7))
                    }
                }
                if holding.assetType == .stock || holding.assetType == .etf || holding.assetType == .crypto || holding.assetType == .options {
                    Button { showPriceAlerts = true } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.appGold.opacity(0.85))
                    }
                }
                Button { showAddLot = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.appBlue)
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    if holding.isRetirementAccount {
                        retirementAccountBanner
                    } else {
                        TaxProfileBannerView()
                            .environmentObject(taxProfileManager)
                    }
                    summaryCard
                    lotsCard
                    if !dividendEvents.isEmpty {
                        dividendHistoryCard
                    }
                    if !splitEvents.isEmpty {
                        splitHistoryCard
                    }
                    if !transactions.isEmpty {
                        transactionHistoryCard
                    }
                    if !closedLots.isEmpty {
                        closedLotsCard
                    }
                    if holding.assetType == .stock || holding.assetType == .etf {
                        IndustryDetailCard(symbol: holding.symbol)
                    }
                    notesCard
                    accountTypeCard
                }
                .onAppear {
                    noteDraft = holding.notes ?? ""
                    if holding.assetType == .cash { lotsCollapsed = false }
                }
                .padding(16)
                .padding(.bottom, 16)
            }

            // 30-second undo toast
            if undoToastVisible {
                undoToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: undoToastVisible)
        .navigationTitle(holding.symbol)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                trailingToolbarButtons
            }
        }
        .sheet(isPresented: $showDepositCash) {
            DepositCashView()
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showWithdrawCash) {
            WithdrawCashView(availableBalance: openLots.reduce(0) { $0 + $1.remainingQty })
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showAddDividend) {
            AddDividendView(holding: holding)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showAddSplit) {
            AddSplitView(holding: holding)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showPriceAlerts) {
            PriceAlertsView(holding: holding)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showAddLot) {
            AddLotView(holding: holding, lot: nil)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showSellPosition) {
            SellPositionSheet(holding: holding, lots: openLots) { tx, lotSnapshot in
                handleSellCompleted(tx: tx, lotSnapshot: lotSnapshot)
            }
            .environment(\.managedObjectContext, context)
            .environmentObject(taxProfileManager)
        }
        .sheet(item: $lotToEdit) { lot in
            AddLotView(holding: holding, lot: lot)
                .environment(\.managedObjectContext, context)
        }
        .sheet(item: $cashLotToEdit) { lot in
            EditCashEntryView(lot: lot)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showEditHolding) {
            EditHoldingView(holding: holding)
                .environment(\.managedObjectContext, context)
        }
        .sheet(item: $transactionToEdit) { tx in
            EditTransactionView(transaction: tx)
                .environment(\.managedObjectContext, context)
                .environmentObject(taxProfileManager)
        }
        .sheet(item: $lotToSell) { lot in
            SellLotView(holding: holding, lot: lot) { tx, snap in
                handleSellCompleted(tx: tx, lotSnapshot: snap)
            }
            .environment(\.managedObjectContext, context)
            .environmentObject(taxProfileManager)
        }
        .alert("Delete Lot", isPresented: Binding(
            get: { lotToDelete != nil },
            set: { if !$0 { lotToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { lotToDelete = nil }
            Button("Delete", role: .destructive) {
                if let lot = lotToDelete { deleteLot(lot) }
            }
        } message: {
            Text("This will remove Lot #\(lotToDelete?.lotNumber ?? 0). This action cannot be undone.")
        }
        .alert("Clear All Cash Entries?", isPresented: $showResetCashConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { resetCashBalance() }
        } message: {
            Text("This will permanently delete all cash deposit entries and reset your balance to zero. This cannot be undone.")
        }
        .alert("Revert Split", isPresented: $showRevertAlert) {
            Button("Cancel", role: .cancel) { splitToRevert = nil }
            Button("Revert", role: .destructive) {
                if let event = splitToRevert {
                    splitToRevert = nil  // nil before CoreData delete to prevent stale-object access
                    try? SplitService.shared.revertSplit(event, in: context)
                }
            }
        } message: {
            Text(revertAlertMessage)
        }
    }

    // MARK: - Undo Helpers

    private func handleSellCompleted(tx: Transaction, lotSnapshot: (id: UUID, remainingQty: Decimal, isClosed: Bool)) {
        undoTransaction = tx
        undoLotSnapshot = lotSnapshot
        undoToastMessage = "Sale recorded"
        showUndoToast()
    }

    private func showUndoToast() {
        undoWorkItem?.cancel()
        undoToastVisible = true
        let work = DispatchWorkItem {
            withAnimation { undoToastVisible = false }
            undoTransaction = nil
            undoLotSnapshot = nil
        }
        undoWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func performUndo() {
        undoWorkItem?.cancel()
        guard let tx = undoTransaction, let snap = undoLotSnapshot else { return }

        // Restore transaction
        tx.softDelete(reason: .userDeleted)

        // Restore lot state
        if let lot = (try? context.fetch(Lot.fetchRequest()))?.first(where: { $0.id == snap.id }) {
            lot.remainingQty = snap.remainingQty
            lot.isClosed = snap.isClosed
        }

        try? context.save()
        withAnimation { undoToastVisible = false }
        undoTransaction = nil
        undoLotSnapshot = nil
    }

    private var undoToast: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.appGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(undoToastMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("Tap Undo within 30 seconds")
                    .font(.system(size: 11))
                    .foregroundColor(.textSub)
            }
            Spacer()
            Button("Undo") { performUndo() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appBlue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func resetCashBalance() {
        for lot in openLots { lot.softDelete() }
        try? context.save()
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(holding.symbol)
                            .font(AppFont.display(22))
                            .foregroundColor(.textPrimary)
                        AssetTypeChip(type: holding.assetType)
                        if holding.isOptionExpired {
                            SmallChip(label: "EXP", color: .appRed)
                        }
                        if holding.isOption {
                            SmallChip(label: holding.isShortPosition ? "STO" : "BTO",
                                      color: holding.isShortPosition ? .appPurple : .appBlue)
                        }
                    }
                    Text(holding.name)
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                        .lineLimit(1)
                }
                Spacer()
                if holding.assetType == .cash {
                    Button { showEditHolding = true } label: {
                        HStack(spacing: 6) {
                            Text(totalQty.asCurrency)
                                .font(AppFont.mono(18, weight: .bold))
                                .foregroundColor(.appGreen)
                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.appGreen.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                } else if let mv = marketValue {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(mv.asCurrency)
                            .font(AppFont.mono(18, weight: .bold))
                            .foregroundColor(.textPrimary)
                        if let pnl = unrealizedPnL, let pct = unrealizedPnLPercent {
                            HStack(spacing: 4) {
                                Text(pnl.asCurrencySigned)
                                Text("(\(pct.asPercentSigned()))")
                            }
                            .font(AppFont.mono(11))
                            .foregroundColor(Color.pnlColor(pnl))
                        }
                    }
                } else {
                    Text(totalCostBasis.asCurrency)
                        .font(AppFont.mono(18, weight: .bold))
                        .foregroundColor(.textPrimary)
                }
            }

            if holding.assetType != .cash {
                Divider().background(Color.appBorder)

                // Stat tiles
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    if holding.isOption {
                        statTile(label: "STRIKE", value: holding.strikePrice?.asCurrency ?? "—")
                        statTile(label: holding.isShortPosition ? "STO PREMIUM" : "BTO PREMIUM",
                                 value: avgCostPerShare.asCurrency)
                        statTile(label: "CONTRACTS", value: totalQty.asQuantity(maxDecimalPlaces: 0))
                        if let pct = percentToStrike {
                            let label = pct >= 0 ? "% ABOVE STRIKE" : "% BELOW STRIKE"
                            let color: Color = holding.optionType == .call
                                ? (pct >= 0 ? .appGreen : .appRed)
                                : (pct >= 0 ? .appRed : .appGreen)
                            statTileColored(label: label,
                                            value: "\(pct >= 0 ? "+" : "")\(pct.asPercent(decimalPlaces: 2))",
                                            color: color)
                        } else {
                            statTile(label: "% TO STRIKE", value: "—")
                        }
                    } else {
                        statTile(label: "PRICE", value: currentPrice?.asCurrency ?? "—")
                        statTile(label: "AVG COST", value: avgCostPerShare.asCurrency)
                        if let yieldPct = dividendYieldPercent {
                            statTile(label: "YIELD", value: "\(yieldPct.asPercent(decimalPlaces: 2))%")
                        } else {
                            statTile(label: "SHARES", value: totalQty.asQuantity(maxDecimalPlaces: 4))
                        }
                    }
                }

                if let pd = priceData {
                    HStack(spacing: 6) {
                        if pd.isLive {
                            Circle().fill(Color.appGreen).frame(width: 5, height: 5)
                            Text("LIVE")
                                .font(AppFont.mono(9, weight: .bold))
                                .foregroundColor(.appGreen)
                        } else if pd.isStale {
                            Circle().fill(Color.appGold).frame(width: 5, height: 5)
                            Text("\(pd.fetchedAt.minutesSince)m ago")
                                .font(.system(size: 9))
                                .foregroundColor(.appGold)
                        }
                        if pd.dailyChange != 0 {
                            Spacer()
                            Text("Today: \(pd.dailyChange.asCurrencySigned) (\(pd.dailyChangePercent.asPercentSigned()))")
                                .font(AppFont.mono(10))
                                .foregroundColor(Color.pnlColor(pd.dailyChange))
                        }
                    }
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppFont.statLabel)
                .foregroundColor(.textMuted)
                .textCase(.uppercase)
                .kerning(0.5)
            Text(value)
                .font(AppFont.statValue)
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .statTileStyle()
    }

    private func statTileColored(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(AppFont.statLabel)
                .foregroundColor(.textMuted)
                .textCase(.uppercase)
                .kerning(0.5)
            Text(value)
                .font(AppFont.statValue)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .statTileStyle()
    }

    // MARK: - Lots Card

    private var lotsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { lotsCollapsed.toggle() }
                } label: {
                    HStack {
                        Text("LOTS")
                            .sectionTitleStyle()
                        Spacer()
                        Text("\(openLots.count) lot\(openLots.count == 1 ? "" : "s")")
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                        Image(systemName: lotsCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textMuted)
                            .padding(.leading, 4)
                    }
                }
                .buttonStyle(.plain)

                if holding.assetType == .cash && !openLots.isEmpty {
                    Button {
                        showResetCashConfirm = true
                    } label: {
                        Text("Clear All")
                            .font(AppFont.mono(10, weight: .semibold))
                            .foregroundColor(.appRed)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 4)

            if !lotsCollapsed {
            if openLots.isEmpty {
                Text("No lots — tap + to add one.")
                    .font(AppFont.body(13))
                    .foregroundColor(.textMuted)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(openLots.enumerated()), id: \.element.id) { index, lot in
                        VStack(spacing: 0) {
                            LotRowView(
                                lot: lot,
                                currentPrice: currentPrice,
                                isOption: holding.isOption,
                                isCash: holding.assetType == .cash,
                                occSplitWarning: holding.isOption && lot.hasSplitAdjustments,
                                taxEstimate: lotTaxEstimate(for: lot),
                                ltSaving: lotLTSaving(for: lot)
                            )

                            // Action buttons
                            HStack(spacing: 8) {
                                let closeLabel: String = holding.isOption
                                    ? (holding.isShortPosition ? "BTC" : "STC")
                                    : (holding.assetType == .cash ? "Withdraw" : "Sell")
                                let closeColor: Color = holding.isOption && holding.isShortPosition
                                    ? .appPurple : .appRed
                                lotActionButton(label: closeLabel, color: closeColor, icon: "arrow.down.circle") {
                                    lotToSell = lot
                                }
                                lotActionButton(label: "Edit", color: .appBlue, icon: "pencil") {
                                    if holding.assetType == .cash {
                                        cashLotToEdit = lot
                                    } else {
                                        lotToEdit = lot
                                    }
                                }
                                lotActionButton(label: "Delete", color: .textMuted, icon: "trash") {
                                    lotToDelete = lot
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }

                        if index < openLots.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()

                // Lots tab disclaimer footer (Tier 1 variant)
                Text(TaxDisclaimer.lotsTier1)
                    .font(AppFont.body(10))
                    .foregroundColor(.textMuted)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            } // end if !lotsCollapsed
        }
    }

    // MARK: - Dividend History Card

    private var dividendHistoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { dividendsCollapsed.toggle() }
            } label: {
                HStack {
                    Text("DIVIDENDS")
                        .sectionTitleStyle()
                    Spacer()
                    if dividendYTD > 0 {
                        Text("\(dividendYTD.asCurrency) YTD")
                            .font(AppFont.mono(10))
                            .foregroundColor(.appGold)
                    }
                    Text("\(dividendEvents.count)")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                    Image(systemName: dividendsCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !dividendsCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(dividendEvents.enumerated()), id: \.element.id) { index, event in
                        DividendEventRowView(event: event)
                        if index < dividendEvents.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    // MARK: - Split History Card

    private var splitHistoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { splitsCollapsed.toggle() }
            } label: {
                HStack {
                    Text("SPLITS")
                        .sectionTitleStyle()
                    Spacer()
                    Text("\(splitEvents.count)")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                    Image(systemName: splitsCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !splitsCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(splitEvents.enumerated()), id: \.element.id) { index, event in
                        SplitEventRowView(event: event) {
                            revertAlertMessage = "Revert the \(event.ratioString) split applied on \(event.splitDate.formatted(.dateTime.month(.abbreviated).day().year()))? All lot quantities and cost bases will be restored to their pre-split values."
                            splitToRevert = event
                            showRevertAlert = true
                        }
                        if index < splitEvents.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    // MARK: - Closed Lots Card

    private var closedLotsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { closedLotsCollapsed.toggle() }
            } label: {
                HStack {
                    Text("CLOSED LOTS")
                        .sectionTitleStyle()
                    Spacer()
                    Text("\(closedLots.count) lot\(closedLots.count == 1 ? "" : "s")")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                    Image(systemName: closedLotsCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !closedLotsCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(closedLots.enumerated()), id: \.element.id) { index, lot in
                        ClosedLotRowView(lot: lot,
                                         isOption: holding.isOption,
                                         data: closedLotDataMap[lot.id])
                            .contextMenu {
                                Button {
                                    lotToEdit = lot
                                } label: {
                                    Label("Edit Lot", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    lotToDelete = lot
                                } label: {
                                    Label("Delete Lot", systemImage: "trash")
                                }
                            }
                        if index < closedLots.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    // MARK: - Transaction History Card

    private var transactionHistoryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { transactionsCollapsed.toggle() }
            } label: {
                HStack {
                    Text("TRANSACTIONS")
                        .sectionTitleStyle()
                    Spacer()
                    Text("\(transactions.count)")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                    Image(systemName: transactionsCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !transactionsCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(transactions.enumerated()), id: \.element.id) { index, tx in
                        Button {
                            transactionToEdit = tx
                        } label: {
                            TransactionRowView(transaction: tx, isOption: holding.isOption,
                                              isShortPosition: holding.isShortPosition)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTransaction(tx)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if index < transactions.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    // MARK: - Lot Action Button

    private func lotActionButton(label: String, color: Color, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Retirement Account Banner

    private var retirementAccountBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 14))
                .foregroundColor(.appPurple)
            Text("Retirement Account — tax estimates suppressed")
                .font(AppFont.body(13, weight: .medium))
                .foregroundColor(.appPurple)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appPurple.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.appPurple.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Account Type Card

    private var accountTypeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACCOUNT")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Toggle(isOn: Binding(
                get: { holding.isRetirementAccount },
                set: { holding.isRetirementAccount = $0; try? context.save() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Retirement Account")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textPrimary)
                    Text("IRA, Roth IRA, 401k — tax estimates suppressed")
                        .font(.system(size: 11))
                        .foregroundColor(.textSub)
                }
            }
            .tint(.appPurple)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .cardStyle()
    }

    // MARK: - Notes Card

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOTES")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                if isEditingNote {
                    TextEditor(text: $noteDraft)
                        .font(AppFont.body(14))
                        .foregroundColor(.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80)
                        .padding(16)

                    Divider().background(Color.appBorder)

                    HStack {
                        Spacer()
                        Button("Done") {
                            holding.notes = noteDraft.isEmpty ? nil : noteDraft
                            try? context.save()
                            isEditingNote = false
                        }
                        .font(AppFont.body(13, weight: .semibold))
                        .foregroundColor(.appBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                } else {
                    Button {
                        noteDraft = holding.notes ?? ""
                        isEditingNote = true
                    } label: {
                        HStack(spacing: 10) {
                            Text(holding.notes?.isEmpty == false ? holding.notes! : "Tap to add a note…")
                                .font(AppFont.body(14))
                                .foregroundColor(holding.notes?.isEmpty == false ? .textPrimary : .textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                        }
                        .padding(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                isEditingNote ? Color.appBlue.opacity(0.5) : Color.appBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Delete

    private func deleteLot(_ lot: Lot) {
        // For closed lots, also soft-delete linked sell transactions
        if lot.isClosed {
            for tx in transactions where tx.lotId == lot.id {
                tx.softDelete(reason: .userDeleted)
            }
        }
        lot.softDelete()
        try? context.save()
        lotToDelete = nil
    }

    private func deleteTransaction(_ tx: Transaction) {
        tx.softDelete(reason: .userDeleted)
        try? context.save()
    }
}

// MARK: - Lot Row View

struct LotRowView: View {
    let lot: Lot
    let currentPrice: Decimal?
    let isOption: Bool
    var isCash: Bool = false
    var occSplitWarning: Bool = false
    var taxEstimate: TaxEstimate? = nil
    var ltSaving: Decimal? = nil

    private var marketValue: Decimal? {
        guard let price = currentPrice else { return nil }
        return (lot.remainingQty * price).rounded(to: 2)
    }

    private var unrealizedPnL: Decimal? {
        guard let mv = marketValue else { return nil }
        let basis = (lot.remainingQty * lot.splitAdjustedCostBasisPerShare).rounded(to: 2)
        return (mv - basis).rounded(to: 2)
    }

    private var unrealizedPnLPercent: Decimal? {
        guard let pnl = unrealizedPnL else { return nil }
        let basis = lot.remainingQty * lot.splitAdjustedCostBasisPerShare
        guard basis > 0 else { return nil }
        return ((pnl / basis) * 100).rounded(to: 2)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Lot number badge
                Text("#\(lot.lotNumber)")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundColor(.appBlue)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(AppFont.mono(12, weight: .bold))
                            .foregroundColor(.textPrimary)
                        if isCash, let note = lot.sourceNote {
                            Text(note)
                                .font(AppFont.mono(10, weight: .semibold))
                                .foregroundColor(.appBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.appBlue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if !isCash { ltBadge }
                    }
                    Text("\(lot.remainingQty.asQuantity(maxDecimalPlaces: 4)) \(isOption ? "contracts" : "shares") @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textSub)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    if let mv = marketValue {
                        Text(mv.asCurrency)
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        if let pnl = unrealizedPnL, let pct = unrealizedPnLPercent {
                            Text("\(pnl.asCurrencySigned) (\(pct.asPercentSigned()))")
                                .font(AppFont.mono(10))
                                .foregroundColor(Color.pnlColor(pnl))
                        }
                        if let est = taxEstimate {
                            Text("~ \(est.totalTax.asCurrency) est. tax")
                                .font(AppFont.mono(10))
                                .foregroundColor(.textMuted)
                        }
                    } else {
                        Text(lot.totalCostBasis.asCurrency)
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("cost basis")
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !isOption {
                ltProgressBar
            }

            if let saving = ltSaving {
                ltAdvisoryBanner(saving: saving)
            }

            if occSplitWarning {
                occSplitWarningBanner
            }
        }
    }

    // MARK: - LT Progress Bar

    @ViewBuilder
    private var ltProgressBar: some View {
        if !lot.isLongTerm {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let days = lot.daysToLongTerm {
                        Text("\(lot.daysHeld) / 366 days")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.textMuted)
                        Spacer()
                        if let qualDate = lot.longTermQualifyingDate {
                            Text("LT on \(qualDate.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(days <= 60 ? .appGold : .textMuted)
                        }
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.surfaceAlt)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(lot.isApproachingLongTerm ? Color.appGold : Color.appBlue)
                            .frame(width: geo.size.width * lot.ltProgress, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - LT Advisory Banner

    private func ltAdvisoryBanner(saving: Decimal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.appGold)
            VStack(alignment: .leading, spacing: 2) {
                let days = lot.daysToLongTerm ?? 0
                Text("HOLD \(days) MORE DAY\(days == 1 ? "" : "S") — SAVE ~\(saving.asCurrency) IN TAX")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.appGold)
                Text("Selling now triggers short-term rates. Waiting qualifies for lower long-term rates.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.appGold.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appGold.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(width: 3)
                .foregroundColor(.appGold),
            alignment: .leading
        )
    }

    private var occSplitWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.appGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("OCC ADJUSTMENT — REVIEW REQUIRED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.appGold)
                Text("A split was applied to the underlying. Verify your strike price and contract terms have been OCC-adjusted.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color.appGold.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appGold.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(width: 3)
                .foregroundColor(.appGold),
            alignment: .leading
        )
    }

    @ViewBuilder
    private var ltBadge: some View {
        if lot.isLongTerm {
            SmallChip(label: "LT", color: .appGreen)
        } else if lot.isApproachingLongTerm, let days = lot.daysToLongTerm {
            SmallChip(label: "LT in \(days)d", color: .appGold)
        } else {
            SmallChip(label: "ST", color: .textMuted)
        }
    }
}

// MARK: - Closed Lot Row View

struct ClosedLotRowView: View {
    let lot: Lot
    let isOption: Bool
    let data: PositionDetailView.ClosedLotData?

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(lot.lotNumber)")
                .font(AppFont.mono(11, weight: .bold))
                .foregroundColor(.textMuted)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let d = data {
                        Text(d.saleDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(AppFont.mono(12, weight: .bold))
                            .foregroundColor(.textSub)
                        SmallChip(label: d.isLongTermAtSale ? "LT" : "ST",
                                   color: d.isLongTermAtSale ? .appGreen : .appGold)
                    } else {
                        Text(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(AppFont.mono(12, weight: .bold))
                            .foregroundColor(.textSub)
                    }
                    SmallChip(label: "CLOSED", color: .textMuted)
                }
                if let d = data {
                    let salePrice = lot.originalQty > 0
                        ? (d.proceeds / lot.originalQty).rounded(to: 2)
                        : Decimal(0)
                    Text("\(lot.originalQty.asQuantity(maxDecimalPlaces: 4)) \(isOption ? "contracts" : "shares") · sold @ \(salePrice.asCurrency)  ·  bought \(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year())) @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textMuted)
                } else {
                    Text("\(lot.originalQty.asQuantity(maxDecimalPlaces: 4)) \(isOption ? "contracts" : "shares") · bought \(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year())) @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textMuted)
                }
            }

            Spacer()

            if let d = data {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(d.proceeds.asCurrency)
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(.textSub)
                    HStack(spacing: 2) {
                        Text(d.gain >= 0 ? "+" : "")
                            .font(AppFont.mono(10))
                            .foregroundColor(d.gain >= 0 ? .appGreen : .appRed)
                        Text(d.gain.asCurrency)
                            .font(AppFont.mono(10, weight: .semibold))
                            .foregroundColor(d.gain >= 0 ? .appGreen : .appRed)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(lot.totalCostBasis.asCurrency)
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(.textSub)
                    Text("cost basis")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Transaction Row View

struct TransactionRowView: View {
    @ObservedObject var transaction: Transaction
    let isOption: Bool
    var isShortPosition: Bool = false

    private var isBuy: Bool { transaction.type == .buy || transaction.type == .drip || transaction.type == .transferIn }

    private var typeLabel: String {
        if isOption {
            if transaction.type == .buy  { return isShortPosition ? "STO" : "BTO" }
            if transaction.type == .sell { return isShortPosition ? "BTC" : "STC" }
        }
        switch transaction.type {
        case .buy:         return "BUY"
        case .sell:        return "SELL"
        case .drip:        return "DRIP"
        case .dividend:    return "DIV"
        case .split:       return "SPLIT"
        case .transferIn:  return "IN"
        case .transferOut: return "OUT"
        }
    }

    private var typeColor: Color {
        // STO opening = income → green; BTC closing = cost → red
        if isOption && isShortPosition {
            return transaction.type == .buy ? Color.appGreen : Color.appRed
        }
        return isBuy ? Color.appBlue : Color.appRed
    }

    private var amountColor: Color {
        // STO opening income: show in green
        if isOption && isShortPosition && transaction.type == .buy { return .appGreen }
        return .textPrimary
    }

    private var amountDisplay: String {
        if isOption && isShortPosition && transaction.type == .buy {
            return "+\(transaction.totalAmount.asCurrency)"
        }
        return transaction.totalAmount.asCurrency
    }

    var body: some View {
        HStack(spacing: 12) {
            // Type badge
            Text(typeLabel)
                .font(AppFont.mono(10, weight: .bold))
                .foregroundColor(typeColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.tradeDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.textPrimary)
                if transaction.quantity > 0 {
                    Text("\(transaction.quantity.asQuantity(maxDecimalPlaces: 4)) \(isOption ? "contracts" : "shares") @ \(transaction.pricePerShare.asCurrency)")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textSub)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(amountDisplay)
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(amountColor)
                if transaction.fee > 0 {
                    Text("fee \(transaction.fee.asCurrency)")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Dividend Event Row View

struct DividendEventRowView: View {
    let event: DividendEvent

    var body: some View {
        HStack(spacing: 12) {
            // Type badge
            Text(event.isReinvested ? "DRIP" : "DIV")
                .font(AppFont.mono(10, weight: .bold))
                .foregroundColor(event.isReinvested ? .appGold : .appGreen)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.payDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text("\(event.dividendPerShare.asCurrency)/share × \(event.sharesHeld.asQuantity(maxDecimalPlaces: 4))")
                    .font(AppFont.mono(11))
                    .foregroundColor(.textSub)
                if event.isReinvested && event.reinvestedShares > 0 {
                    Text("\(event.reinvestedShares.asQuantity(maxDecimalPlaces: 6)) shares @ \(event.reinvestedPricePerShare.asCurrency)")
                        .font(AppFont.mono(10))
                        .foregroundColor(.appGold)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(event.grossAmount.asCurrency)
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(event.isReinvested ? .appGold : .appGreen)
                if let exDiv = event.exDividendDate {
                    Text("ex \(exDiv.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Split Event Row View

struct SplitEventRowView: View {
    let event: SplitEvent
    let onRevert: () -> Void

    private var canRevert: Bool {
        guard !event.isDeleted, !event.isFault else { return false }
        guard let snap = try? PersistenceController.shared.container.viewContext
            .fetch(SplitSnapshot.forSplitEvent(event.id)).first
        else { return false }
        return snap.isStillRevertable
    }

    var body: some View {
        HStack(spacing: 12) {
            // Direction badge
            Text(event.isForward ? "FWD" : "REV")
                .font(AppFont.mono(10, weight: .bold))
                .foregroundColor(event.isForward ? .appGreen : .appRed)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.splitDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    Text(event.ratioString)
                        .font(AppFont.mono(11, weight: .semibold))
                        .foregroundColor(event.isForward ? .appGreen : .appRed)
                    Text(event.entryMethod == .manual ? "Manual" : "Auto-detected")
                        .font(AppFont.body(10))
                        .foregroundColor(.textMuted)
                }
            }

            Spacer()

            if canRevert {
                Button {
                    onRevert()
                } label: {
                    Text("Revert")
                        .font(AppFont.mono(11, weight: .semibold))
                        .foregroundColor(.appRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.appRed.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            } else {
                Text("×\(event.splitMultiplier.asQuantity(maxDecimalPlaces: 4))")
                    .font(AppFont.mono(11))
                    .foregroundColor(.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
