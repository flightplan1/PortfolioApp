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

    @State private var showAddLot        = false
    @State private var showSellPosition  = false
    @State private var showDepositCash   = false
    @State private var showWithdrawCash  = false
    @State private var lotsCollapsed        = true
    @State private var transactionsCollapsed = true
    @State private var closedLotsCollapsed   = true
    @State private var lotToEdit:   Lot?
    @State private var lotToSell:   Lot?
    @State private var lotToDelete: Lot?

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
    }

    // MARK: - Computed

    private var openLots: [Lot] { Array(lots) }

    private var totalQty: Decimal {
        openLots.reduce(0) { $0 + $1.remainingQty }
    }

    private var totalCostBasis: Decimal {
        openLots.reduce(0) { $0 + $1.totalCostBasis }
    }

    private var avgCostPerShare: Decimal {
        guard totalQty > 0 else { return 0 }
        // Options: totalCostBasis includes ×100 multiplier — divide by totalQty×100 for premium per share
        let denom = holding.isOption ? totalQty * 100 : totalQty
        return (totalCostBasis / denom).rounded(to: 4)
    }

    private var priceData: PriceData? {
        priceService.price(for: holding.symbol)
    }

    private var currentPrice: Decimal? { priceData?.currentPrice }

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

    /// Computes a tax estimate for selling a lot at the current price.
    private func lotTaxEstimate(for lot: Lot) -> TaxEstimate? {
        guard taxProfileManager.isProfileComplete,
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
        guard !lot.isLongTerm,
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

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    TaxProfileBannerView()
                        .environmentObject(taxProfileManager)
                    summaryCard
                    lotsCard
                    if !transactions.isEmpty {
                        transactionHistoryCard
                    }
                    if !closedLots.isEmpty {
                        closedLotsCard
                    }
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
                HStack(spacing: 4) {
                    if holding.assetType == .cash {
                        Button {
                            showWithdrawCash = true
                        } label: {
                            Text("Withdraw")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.appRed)
                        }
                        Button {
                            showDepositCash = true
                        } label: {
                            Text("Deposit")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.appBlue)
                        }
                    } else {
                        if !openLots.isEmpty {
                            Button {
                                showSellPosition = true
                            } label: {
                                Text("Sell")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.appRed)
                            }
                        }
                        Button {
                            showAddLot = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.appBlue)
                        }
                    }
                }
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
                    Text(totalQty.asCurrency)
                        .font(AppFont.mono(18, weight: .bold))
                        .foregroundColor(.appGreen)
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
                    } else {
                        statTile(label: "PRICE", value: currentPrice?.asCurrency ?? "—")
                        statTile(label: "AVG COST", value: avgCostPerShare.asCurrency)
                        statTile(label: "SHARES", value: totalQty.asQuantity(maxDecimalPlaces: 4))
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

    // MARK: - Lots Card

    private var lotsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                                    lotToEdit = lot
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
                        ClosedLotRowView(lot: lot, isOption: holding.isOption)
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
                        TransactionRowView(transaction: tx, isOption: holding.isOption)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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

    // MARK: - Delete

    private func deleteLot(_ lot: Lot) {
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

    private var realizedPnL: Decimal {
        // Total cost basis is tracked on the lot; realized proceeds are in transactions
        // Approximate: totalCostBasis is what was paid; remaining = 0 means fully sold
        // We show cost basis since we don't store total proceeds on the lot directly
        lot.totalCostBasis
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(lot.lotNumber)")
                .font(AppFont.mono(11, weight: .bold))
                .foregroundColor(.textMuted)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(AppFont.mono(12, weight: .bold))
                        .foregroundColor(.textSub)
                    SmallChip(label: "CLOSED", color: .textMuted)
                }
                Text("\(lot.originalQty.asQuantity(maxDecimalPlaces: 4)) \(isOption ? "contracts" : "shares") @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                    .font(AppFont.mono(11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(lot.totalCostBasis.asCurrency)
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(.textSub)
                Text("cost basis")
                    .font(AppFont.mono(10))
                    .foregroundColor(.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Transaction Row View

struct TransactionRowView: View {
    let transaction: Transaction
    let isOption: Bool

    private var isBuy: Bool { transaction.type == .buy || transaction.type == .drip || transaction.type == .transferIn }
    private var typeColor: Color { isBuy ? Color.appBlue : Color.appRed }

    var body: some View {
        HStack(spacing: 12) {
            // Type badge
            Text(transaction.type == .buy ? "BUY" :
                 transaction.type == .sell ? "SELL" :
                 transaction.type == .drip ? "DRIP" :
                 transaction.type == .dividend ? "DIV" :
                 transaction.type == .split ? "SPLIT" :
                 transaction.type == .transferIn ? "IN" : "OUT")
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
                Text(transaction.totalAmount.asCurrency)
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(.textPrimary)
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
