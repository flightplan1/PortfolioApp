import SwiftUI
import CoreData
import Charts

// MARK: - Dashboard View

struct DashboardView: View {

    @EnvironmentObject private var priceService: PriceService
    @Environment(\.managedObjectContext) private var viewContext

    // All active holdings
    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .default)
    private var holdings: FetchedResults<Holding>

    // All open lots (non-closed, non-deleted) — used for portfolio value / LT-ST / allocation
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isClosed == NO AND isSoftDeleted == NO")
    )
    private var allOpenLots: FetchedResults<Lot>

    // All lots including closed — needed to look up cost basis for sell transactions
    @FetchRequest(sortDescriptors: [])
    private var allLots: FetchedResults<Lot>

    // Sell transactions in the current calendar year — for realized P&L
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(
            format: "typeRaw == %@ AND isSoftDeleted == NO AND tradeDate >= %@",
            TransactionType.sell.rawValue,
            (Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()) as NSDate
        )
    )
    private var sellsThisYear: FetchedResults<Transaction>

    @State private var isValueBlurred = false

    // MARK: - Derived Maps

    /// holdingId → Holding — avoids O(n²) lookups in computed properties.
    private var holdingMap: [UUID: Holding] {
        Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })
    }

    // MARK: - Computed: Portfolio Value

    private var totalPortfolioValue: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId] else { return sum }
            // Options: no live contract price on free tier — carry at cost basis
            if h.isOption { return sum + lot.totalCostBasis }
            guard let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
        }
    }

    private var totalCostBasis: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId] else { return sum }
            return sum + (lot.remainingQty * lot.splitAdjustedCostBasisPerShare * h.lotMultiplier).rounded(to: 2)
        }
    }

    private var unrealizedPnL: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId],
                  !h.isOption,   // no live option prices — exclude from unrealized P&L
                  let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.unrealizedPnL(at: price, multiplier: h.lotMultiplier) * h.pnlDirection
        }
    }

    private var todayChange: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId],
                  !h.isOption,   // underlying stock daily change ≠ option daily change
                  let change = priceService.dailyChange(for: h.symbol) else { return sum }
            return sum + (lot.remainingQty * change * h.lotMultiplier * h.pnlDirection).rounded(to: 2)
        }
    }

    private var todayChangePct: Decimal {
        let prev = totalPortfolioValue - todayChange
        guard prev != 0 else { return 0 }
        return ((todayChange / prev) * 100).rounded(to: 2)
    }

    // Realized P&L for the current calendar year, plus the cost basis of sold positions.
    // Both are computed in one pass over sellsThisYear to avoid building the lotMap twice.
    // Note: uses current splitAdjustedCostBasisPerShare — accurate unless a split occurred
    // after the sale (handled properly in Phase 6 Tax Module).
    private var realizedPnLStats: (pnl: Decimal, soldCostBasis: Decimal) {
        let lotMap = Dictionary(uniqueKeysWithValues: allLots.map { ($0.id, $0) })
        var pnl = Decimal(0)
        var soldCostBasis = Decimal(0)
        for tx in sellsThisYear {
            let txAmt = tx.totalAmount
            guard let lotId = tx.lotId, let lot = lotMap[lotId] else {
                pnl += txAmt
                continue
            }
            let h = holdingMap[lot.holdingId]
            let m = h?.lotMultiplier ?? 1
            let dir = h?.pnlDirection ?? 1
            let costBasis = (tx.quantity * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            // BTO→STC: pnl = proceeds − costBasis (dir = +1)
            // STO→BTC: pnl = costBasis − costToClose (dir = -1, txAmt = costToClose)
            pnl += (txAmt - costBasis) * dir
            soldCostBasis += costBasis
        }
        return (pnl, soldCostBasis)
    }

    private var realizedPnLThisYear: Decimal { realizedPnLStats.pnl }

    private var realizedPnLPct: Decimal? {
        let basis = realizedPnLStats.soldCostBasis
        guard basis > 0 else { return nil }
        return (realizedPnLStats.pnl / basis * 100).rounded(to: 2)
    }

    private var unrealizedPnLPct: Decimal? {
        guard totalCostBasis > 0 else { return nil }
        return (unrealizedPnL / totalCostBasis * 100).rounded(to: 2)
    }

    private var arePricesStale: Bool {
        priceService.lastFetchedAt?.isOlderThan15Minutes ?? false
    }

    // MARK: - Computed: Allocation

    private var allocationSlices: [AllocationSlice] {
        var valueByType: [AssetType: Decimal] = [:]
        for lot in allOpenLots {
            guard let h = holdingMap[lot.holdingId] else { continue }
            let contrib: Decimal
            if h.isOption {
                // Carry options at cost basis — no live contract price on free tier
                contrib = lot.totalCostBasis
            } else {
                let price = priceService.currentPrice(for: h.symbol) ?? lot.splitAdjustedCostBasisPerShare
                contrib = lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
            }
            if contrib > 0 { valueByType[h.assetType, default: 0] += contrib }
        }
        let total = valueByType.values.reduce(Decimal(0), +)
        guard total > 0 else { return [] }
        return valueByType
            .sorted { $0.value > $1.value }
            .map { type, value in
                AllocationSlice(
                    assetType: type,
                    value: value,
                    percentage: Double(truncating: (value / total * 100) as NSDecimalNumber)
                )
            }
    }

    // MARK: - Computed: Holdings Weight

    private var holdingWeights: [HoldingWeight] {
        let total = totalPortfolioValue
        guard total > 0 else { return [] }
        return holdings.compactMap { h -> HoldingWeight? in
            let mv = allOpenLots
                .filter { $0.holdingId == h.id }
                .reduce(Decimal(0)) { sum, lot in
                    if h.isOption { return sum + lot.totalCostBasis }
                    let price = priceService.currentPrice(for: h.symbol) ?? lot.splitAdjustedCostBasisPerShare
                    return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
                }
            guard mv > 0 else { return nil }
            let pct = Double(truncating: (mv / total * 100) as NSDecimalNumber)
            return HoldingWeight(id: h.id, symbol: h.symbol, name: h.name,
                                 assetType: h.assetType, marketValue: mv, weightPct: pct)
        }
        .sorted { $0.weightPct > $1.weightPct }
    }

    // MARK: - Computed: Top Movers

    private var topMovers: [MoverItem] {
        holdings.compactMap { h -> MoverItem? in
            guard !h.isOption,   // options share symbol with underlying — would show stock movement
                  let pct = priceService.dailyChangePercent(for: h.symbol),
                  let amt = priceService.dailyChange(for: h.symbol) else { return nil }
            return MoverItem(id: h.id, symbol: h.symbol, name: h.name,
                             changePct: pct, changeAmt: amt)
        }
        .sorted { abs($0.changePct) > abs($1.changePct) }
        .prefix(5)
        .map { $0 }
    }

    // MARK: - Computed: LT / ST

    private var ltValue: Decimal {
        allOpenLots.filter { $0.isLongTerm }.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId],
                  !h.isOption,
                  let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
        }
    }

    private var stValue: Decimal {
        allOpenLots.filter { !$0.isLongTerm }.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId],
                  !h.isOption,
                  let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if holdings.isEmpty {
                    emptyState
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { refreshButton }
        }
        .task {
            await priceService.refreshAllPrices(holdings: Array(holdings))
        }
        .onChange(of: priceService.lastFetchedAt) {
            WidgetDataWriter.write(
                totalValue: totalPortfolioValue,
                todayChange: todayChange,
                todayChangePct: todayChangePct
            )
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                portfolioHeaderCard
                pnlSummaryStrip
                if !allocationSlices.isEmpty {
                    allocationCard
                }
                if !holdingWeights.isEmpty {
                    holdingsWeightCard
                }
                if !topMovers.isEmpty {
                    topMoversCard
                }
                ltStCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            await priceService.refreshAllPrices(holdings: Array(holdings))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var refreshButton: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if priceService.isFetching {
                ProgressView()
                    .tint(.textSub)
            } else {
                Button {
                    Task { await priceService.refreshAllPrices(holdings: Array(holdings)) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textSub)
                }
                .accessibilityLabel("Refresh prices")
            }
        }
    }

    // MARK: - Portfolio Header Card

    private var portfolioHeaderCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status bar
            HStack(spacing: 6) {
                Circle()
                    .fill(Date.isUSMarketHours ? Color.appGreen : Color.textMuted)
                    .frame(width: 6, height: 6)
                Text(Date.isUSMarketHours ? "Market Open" : "Market Closed")
                    .font(AppFont.body(11))
                    .foregroundColor(Date.isUSMarketHours ? .appGreen : .textMuted)
                Spacer()
                if let updated = priceService.lastFetchedAt {
                    HStack(spacing: 4) {
                        if arePricesStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.appGold)
                        }
                        Text("Updated \(updated.timeAgoDescription)")
                            .font(AppFont.body(11))
                            .foregroundColor(arePricesStale ? .appGold : .textMuted)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Portfolio value
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(isValueBlurred ? "••••••" : totalPortfolioValue.asCurrencyCompact)
                    .font(AppFont.mono(38, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Button {
                    isValueBlurred.toggle()
                } label: {
                    Image(systemName: isValueBlurred ? "eye.slash" : "eye")
                        .font(.system(size: 16))
                        .foregroundColor(.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isValueBlurred ? "Show portfolio values" : "Hide portfolio values")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            // Today change
            HStack(spacing: 6) {
                Image(systemName: todayChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(isValueBlurred ? "•••• (••%)" : "\(todayChange.asCurrencySigned) (\(todayChangePct.asPercentSigned()))")
                    .font(AppFont.mono(13, weight: .semibold))
                Text("today")
                    .font(AppFont.body(12))
                    .foregroundColor(.textMuted)
                Spacer()
            }
            .foregroundColor(Color.pnlColor(todayChange))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .cardStyle()
    }

    // MARK: - P&L Summary Strip

    private var pnlSummaryStrip: some View {
        HStack(spacing: 10) {
            statTile(
                label: "UNREALIZED",
                value: isValueBlurred ? "••••" : unrealizedPnL.asCurrencyCompact,
                isSignedColor: true,
                isPositive: unrealizedPnL >= 0,
                pct: unrealizedPnLPct
            )
            statTile(
                label: "REALIZED YTD",
                value: isValueBlurred ? "••••" : realizedPnLThisYear.asCurrencyCompact,
                isSignedColor: true,
                isPositive: realizedPnLThisYear >= 0,
                pct: realizedPnLPct
            )
            statTile(
                label: "TODAY P&L",
                value: isValueBlurred ? "••••" : todayChange.asCurrencyCompact,
                isSignedColor: true,
                isPositive: todayChange >= 0,
                pct: todayChangePct
            )
        }
    }

    private func statTile(
        label: String,
        value: String,
        isSignedColor: Bool,
        isPositive: Bool,
        pct: Decimal? = nil
    ) -> some View {
        let valueColor: Color = isSignedColor
            ? Color.pnlColor(isPositive ? Decimal(1) : Decimal(-1))
            : Color.textPrimary
        let pctStr = pct.map { ", \($0.asPercentSigned())" } ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppFont.statLabel)
                .foregroundColor(.textMuted)
                .kerning(0.5)
            Text(value)
                .font(AppFont.statValue)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let pct {
                Text(isValueBlurred ? "••%" : pct.asPercentSigned())
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundColor(valueColor.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statTileStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isValueBlurred ? "\(label): hidden" : "\(label): \(value)\(pctStr)")
    }

    // MARK: - Allocation Card

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ALLOCATION")
                    .sectionTitleStyle()
                Spacer()
                NavigationLink(destination: AllocationsView()) {
                    HStack(spacing: 4) {
                        Text("See All")
                            .font(AppFont.body(12))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.appBlue)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 24) {
                Chart(allocationSlices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.percentage),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(3)
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(allocationSlices) { slice in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(slice.color)
                                .frame(width: 10, height: 10)
                            Text(slice.assetType.pluralName)
                                .font(AppFont.body(12))
                                .foregroundColor(.textSub)
                            Spacer()
                            Text(String(format: "%.1f%%", slice.percentage))
                                .font(AppFont.mono(12, weight: .medium))
                                .foregroundColor(.textPrimary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .cardStyle()
    }

    // MARK: - Holdings Weight Card

    private func weightRow(item: HoldingWeight) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(item.symbol)
                    .font(AppFont.mono(13, weight: .bold))
                    .foregroundColor(.textPrimary)
                    .frame(minWidth: 52, alignment: .leading)

                Text(item.name)
                    .font(AppFont.body(12))
                    .foregroundColor(.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(isValueBlurred ? "••••" : item.marketValue.asCurrencyCompact)
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(String(format: "%.1f%%", item.weightPct))
                        .font(AppFont.mono(11, weight: .medium))
                        .foregroundColor(.textSub)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.textMuted)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.appBorder)
                        .frame(height: 4)
                    Capsule()
                        .fill(item.barColor)
                        .frame(width: geo.size.width * item.weightPct / 100, height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private var holdingsWeightCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PORTFOLIO WEIGHTS")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(holdingWeights) { item in
                Group {
                    if let holding = holdingMap[item.id] {
                        NavigationLink(destination: holding.isTreasury
                            ? AnyView(TreasuryDetailView(holding: holding))
                            : AnyView(PositionDetailView(holding: holding))
                        ) {
                            weightRow(item: item)
                        }
                        .buttonStyle(.plain)
                    } else {
                        weightRow(item: item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)

                if item.id != holdingWeights.last?.id {
                    Divider()
                        .background(Color.appBorder)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 8)
        }
        .cardStyle()
    }

    // MARK: - Top Movers Card

    private var topMoversCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TOP MOVERS")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(topMovers) { mover in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mover.symbol)
                            .font(AppFont.mono(13, weight: .bold))
                            .foregroundColor(.textPrimary)
                        if priceService.isStale(for: mover.symbol) {
                            Text("STALE")
                                .font(AppFont.mono(8, weight: .medium))
                                .foregroundColor(.appGold)
                                .kerning(0.5)
                        }
                    }
                    .frame(minWidth: 52, alignment: .leading)

                    Text(mover.name)
                        .font(AppFont.body(12))
                        .foregroundColor(.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isValueBlurred ? "••••" : mover.changeAmt.asCurrencySigned)
                            .font(AppFont.mono(12, weight: .semibold))
                        Text(mover.changePct.asPercentSigned())
                            .font(AppFont.mono(11))
                    }
                    .foregroundColor(Color.pnlColor(mover.changePct))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)

                if mover.id != topMovers.last?.id {
                    Divider()
                        .background(Color.appBorder)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 8)
        }
        .cardStyle()
    }

    // MARK: - LT / ST Card

    private var ltStCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LT / ST BREAKDOWN")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            HStack(spacing: 10) {
                ltStTile(
                    label: "LONG-TERM",
                    value: isValueBlurred ? "••••" : ltValue.asCurrencyCompact,
                    pct: ltValue.percentageOf(totalPortfolioValue),
                    color: .appGreen
                )
                ltStTile(
                    label: "SHORT-TERM",
                    value: isValueBlurred ? "••••" : stValue.asCurrencyCompact,
                    pct: stValue.percentageOf(totalPortfolioValue),
                    color: .appGold
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .cardStyle()
    }

    private func ltStTile(label: String, value: String, pct: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(AppFont.statLabel)
                    .foregroundColor(.textMuted)
                    .kerning(0.5)
            }
            Text(value)
                .font(AppFont.mono(20, weight: .bold))
                .foregroundColor(.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(pct.asPercent())
                .font(AppFont.body(11))
                .foregroundColor(.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statTileStyle()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie")
                .font(.system(size: 52))
                .foregroundColor(.textMuted)
            Text("No Holdings Yet")
                .font(AppFont.body(18, weight: .semibold))
                .foregroundColor(.textPrimary)
            Text("Add holdings from the Holdings tab\nto see your portfolio here.")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Allocation Slice Model

struct AllocationSlice: Identifiable {
    let id = UUID()
    let assetType: AssetType
    let value: Decimal
    let percentage: Double

    var color: Color {
        switch assetType {
        case .stock:    return .chipStock
        case .etf:      return .chipETF
        case .crypto:   return .chipCrypto
        case .options:  return .chipOption
        case .treasury: return .chipTreasury
        case .cash:     return .appGreen
        }
    }
}

// MARK: - Mover Item Model

struct MoverItem: Identifiable {
    let id: UUID
    let symbol: String
    let name: String
    let changePct: Decimal
    let changeAmt: Decimal
}

// MARK: - Holding Weight Model

struct HoldingWeight: Identifiable {
    let id: UUID
    let symbol: String
    let name: String
    let assetType: AssetType
    let marketValue: Decimal
    let weightPct: Double   // 0–100

    var barColor: Color {
        switch assetType {
        case .stock:    return .chipStock
        case .etf:      return .chipETF
        case .crypto:   return .chipCrypto
        case .options:  return .chipOption
        case .treasury: return .chipTreasury
        case .cash:     return .appGreen
        }
    }
}


// MARK: - Preview

#Preview {
    DashboardView()
        .environmentObject(PriceService())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
