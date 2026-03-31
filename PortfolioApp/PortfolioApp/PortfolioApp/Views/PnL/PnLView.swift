import SwiftUI
import CoreData
import Charts

// MARK: - Time Range

enum TimeRange: String, CaseIterable, Identifiable {
    case oneWeek      = "1W"
    case oneMonth     = "1M"
    case threeMonths  = "3M"
    case ytd          = "YTD"
    case oneYear      = "1Y"
    case all          = "All"

    var id: String { rawValue }

    func days(earliestDate: Date) -> Int {
        switch self {
        case .oneWeek:      return 7
        case .oneMonth:     return 30
        case .threeMonths:  return 90
        case .ytd:
            let yearStart = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()
            return max(Calendar.current.dateComponents([.day], from: yearStart, to: Date()).day ?? 1, 1)
        case .oneYear:      return 365
        case .all:
            let d = Calendar.current.dateComponents([.day], from: earliestDate, to: Date()).day ?? 365
            return max(d, 7)
        }
    }
}

// MARK: - Portfolio Data Point (Double for Swift Charts)

struct PortfolioDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

// MARK: - PnL View

struct PnLView: View {

    @EnvironmentObject private var priceService:      PriceService
    @EnvironmentObject private var taxProfileManager: TaxProfileManager
    @StateObject private var histService = HistoricalPriceService()

    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .default)
    private var holdings: FetchedResults<Holding>

    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isClosed == NO AND isSoftDeleted == NO")
    )
    private var allOpenLots: FetchedResults<Lot>

    // Sell transactions this year — for realized P&L stat
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(
            format: "typeRaw == %@ AND isSoftDeleted == NO AND tradeDate >= %@",
            TransactionType.sell.rawValue,
            (Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date()) as NSDate
        )
    )
    private var sellsThisYear: FetchedResults<Transaction>

    @FetchRequest(sortDescriptors: [])
    private var allLots: FetchedResults<Lot>

    @State private var selectedRange: TimeRange = .oneMonth
    @State private var chartData: [PortfolioDataPoint] = []
    @State private var selectedDate: Date?
    @State private var expandedTradeSymbols: Set<String> = []
    @State private var realizedCardCollapsed = false

    private var selectedPoint: PortfolioDataPoint? {
        guard let date = selectedDate else { return nil }
        return chartData.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: - Derived Maps

    private var holdingMap: [UUID: Holding] {
        Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })
    }

    // MARK: - Computed: Current Stats (same as Dashboard)

    private var totalPortfolioValue: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId], h.assetType != .cash,
                  let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
        }
    }

    private var totalCostBasis: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId], h.assetType != .cash else { return sum }
            return sum + (lot.remainingQty * lot.splitAdjustedCostBasisPerShare * h.lotMultiplier).rounded(to: 2)
        }
    }

    private var unrealizedPnL: Decimal { totalPortfolioValue - totalCostBasis }

    private var unrealizedPnLPct: Decimal? {
        guard totalCostBasis > 0 else { return nil }
        return (unrealizedPnL / totalCostBasis * 100).rounded(to: 2)
    }

    private var todayChange: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId], h.assetType != .cash,
                  let change = priceService.dailyChange(for: h.symbol) else { return sum }
            return sum + (lot.remainingQty * change * h.lotMultiplier * h.pnlDirection).rounded(to: 2)
        }
    }

    private var todayChangePct: Decimal {
        let prev = totalPortfolioValue - todayChange
        guard prev != 0 else { return 0 }
        return ((todayChange / prev) * 100).rounded(to: 2)
    }

    // Computes realized P&L and the cost basis of sold positions in one pass.
    // The % is pnl / soldCostBasis — return on capital actually deployed and exited.
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
            let cost = (tx.quantity * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            pnl += (txAmt - cost) * dir
            soldCostBasis += cost
        }
        return (pnl, soldCostBasis)
    }

    private var realizedPnLThisYear: Decimal { realizedPnLStats.pnl }

    private var realizedPnLPct: Decimal? {
        let basis = realizedPnLStats.soldCostBasis
        guard basis > 0 else { return nil }
        return (realizedPnLStats.pnl / basis * 100).rounded(to: 2)
    }

    // MARK: - Tax Year Summary

    /// Estimated total tax on all realized gains this year.
    private var yearTaxEstimate: TaxEstimate? {
        guard taxProfileManager.isProfileComplete else { return nil }
        let pnl = realizedPnLStats.pnl
        guard pnl > 0 else { return nil }
        // Use a blended estimate: all gains realized at average holding period
        // For simplicity, compute aggregate without per-lot dates (LT/ST split comes from individual trades)
        let ltPnl  = ltRealizedPnL
        let stPnl  = stRealizedPnL
        let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
        let ltEst  = ltPnl > 0  ? engine.estimate(gain: ltPnl, purchaseDate: Date().addingTimeInterval(-400 * 86400), saleDate: Date()) : TaxEstimate.zero(gain: 0)
        let stEst  = stPnl > 0  ? engine.estimate(gain: stPnl, purchaseDate: Date().addingTimeInterval(-100 * 86400), saleDate: Date()) : TaxEstimate.zero(gain: 0)
        // Return a combined snapshot
        let totalTax = ltEst.totalTax + stEst.totalTax
        let totalGain = ltPnl + stPnl
        guard totalGain > 0 else { return nil }
        return TaxEstimate(
            gain: totalGain,
            isLongTerm: false,
            isSection1256: false,
            federalTax:  (ltEst.federalTax  + stEst.federalTax).rounded(to: 2),
            federalRate: (totalTax > 0 ? ((ltEst.federalTax + stEst.federalTax) / totalGain * 100) : 0).rounded(to: 2),
            niit:        (ltEst.niit         + stEst.niit).rounded(to: 2),
            stateTax:    (ltEst.stateTax     + stEst.stateTax).rounded(to: 2),
            stateRate:   (totalTax > 0 ? ((ltEst.stateTax + stEst.stateTax) / totalGain * 100) : 0).rounded(to: 2),
            cityTax:     (ltEst.cityTax      + stEst.cityTax).rounded(to: 2),
            cityRate:    (totalTax > 0 ? ((ltEst.cityTax + stEst.cityTax) / totalGain * 100) : 0).rounded(to: 2),
            totalTax:     totalTax.rounded(to: 2),
            netProceeds:  (totalGain - totalTax).rounded(to: 2),
            washSaleWarning: false,
            amtWarning: totalGain > 100_000
        )
    }

    private var ltRealizedPnL: Decimal {
        let lotMap = Dictionary(uniqueKeysWithValues: allLots.map { ($0.id, $0) })
        var pnl = Decimal(0)
        for tx in sellsThisYear {
            guard let lotId = tx.lotId, let lot = lotMap[lotId] else { continue }
            let h   = holdingMap[lot.holdingId]
            let m   = h?.lotMultiplier ?? 1
            let dir = h?.pnlDirection  ?? 1
            let cost = (tx.quantity * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            let txPnl = (tx.totalAmount - cost) * dir
            if lot.isLongTerm { pnl += txPnl }
        }
        return pnl
    }

    private var stRealizedPnL: Decimal {
        let lotMap = Dictionary(uniqueKeysWithValues: allLots.map { ($0.id, $0) })
        var pnl = Decimal(0)
        for tx in sellsThisYear {
            guard let lotId = tx.lotId, let lot = lotMap[lotId] else { continue }
            let h   = holdingMap[lot.holdingId]
            let m   = h?.lotMultiplier ?? 1
            let dir = h?.pnlDirection  ?? 1
            let cost = (tx.quantity * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            let txPnl = (tx.totalAmount - cost) * dir
            if !lot.isLongTerm { pnl += txPnl }
        }
        return pnl
    }

    // MARK: - Chart Helpers

    private var costBasisDouble: Double {
        Double(truncating: totalCostBasis as NSDecimalNumber)
    }

    private var chartIsAboveBasis: Bool {
        (chartData.last?.value ?? 0) >= costBasisDouble
    }

    private var chartLineColor: Color { chartIsAboveBasis ? .appGreen : .appRed }

    private var chartYMin: Double {
        let dataMin = chartData.map(\.value).min() ?? 0
        return min(dataMin, costBasisDouble) * 0.97
    }

    private var chartYMax: Double {
        let dataMax = chartData.map(\.value).max() ?? 0
        return max(dataMax, costBasisDouble) * 1.03
    }

    private var earliestLotDate: Date {
        allOpenLots.map(\.purchaseDate).min() ?? Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    }

    // MARK: - Realized Trade Rows

    struct RealizedTradeRow: Identifiable {
        let id: UUID          // transaction id
        let symbol: String
        let assetType: AssetType
        let isOption: Bool
        let isShortPosition: Bool
        let tradeDate: Date
        let quantity: Decimal
        let pricePerShare: Decimal
        let realizedPnL: Decimal
        let realizedPct: Decimal?

        var actionLabel: String {
            if isOption { return isShortPosition ? "BTC" : "STC" }
            return "SELL"
        }

        var actionColor: Color {
            if isOption && isShortPosition { return .appPurple }
            return .appRed
        }
    }

    private var realizedTradeRows: [RealizedTradeRow] {
        let lotMap = Dictionary(uniqueKeysWithValues: allLots.map { ($0.id, $0) })
        return sellsThisYear.compactMap { tx -> RealizedTradeRow? in
            guard let lotId = tx.lotId,
                  let lot = lotMap[lotId],
                  let h = holdingMap[lot.holdingId] else { return nil }
            let m   = h.lotMultiplier
            let dir = h.pnlDirection
            let cost = (tx.quantity * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            let pnl  = (tx.totalAmount - cost) * dir
            let pct: Decimal? = cost > 0 ? (pnl / cost * 100).rounded(to: 2) : nil
            return RealizedTradeRow(
                id: tx.id,
                symbol: h.symbol,
                assetType: h.assetType,
                isOption: h.isOption,
                isShortPosition: h.isShortPosition,
                tradeDate: tx.tradeDate,
                quantity: tx.quantity,
                pricePerShare: tx.pricePerShare,
                realizedPnL: pnl,
                realizedPct: pct
            )
        }
        .sorted { $0.tradeDate > $1.tradeDate }
    }

    // MARK: - Consolidated Trade Rows (grouped by symbol)

    struct ConsolidatedTradeRow: Identifiable {
        let id: String          // symbol used as stable id
        let symbol: String
        let assetType: AssetType
        let isOption: Bool
        let netPnL: Decimal
        let netPct: Decimal?
        let tradeCount: Int
        let trades: [RealizedTradeRow]
    }

    private var consolidatedTradeRows: [ConsolidatedTradeRow] {
        let grouped: [String: [RealizedTradeRow]] = Dictionary(grouping: realizedTradeRows, by: \.symbol)
        return grouped.map { (symbol: String, trades: [RealizedTradeRow]) -> ConsolidatedTradeRow in
            let netPnL: Decimal = trades.reduce(Decimal(0)) { $0 + $1.realizedPnL }
            let totalCost: Decimal = trades.reduce(Decimal(0)) { (sum: Decimal, t: RealizedTradeRow) -> Decimal in
                guard let pct = t.realizedPct, pct != 0 else { return sum }
                return sum + (t.realizedPnL / (pct / 100)).rounded(to: 2)
            }
            let netPct: Decimal? = totalCost > 0 ? (netPnL / totalCost * 100).rounded(to: 2) : nil
            return ConsolidatedTradeRow(
                id: symbol,
                symbol: symbol,
                assetType: trades[0].assetType,
                isOption: trades[0].isOption,
                netPnL: netPnL,
                netPct: netPct,
                tradeCount: trades.count,
                trades: trades
            )
        }
        .sorted { abs($0.netPnL) > abs($1.netPnL) }
    }

    // MARK: - Per-Holding P&L Rows

    struct HoldingPnLRow: Identifiable {
        let id: UUID
        let symbol: String
        let name: String
        let assetType: AssetType
        let marketValue: Decimal
        let unrealizedPnL: Decimal
        let unrealizedPct: Decimal
        let todayChangePct: Decimal
    }

    private var holdingRows: [HoldingPnLRow] {
        holdings.compactMap { h -> HoldingPnLRow? in
            let lots = allOpenLots.filter { $0.holdingId == h.id }
            guard !lots.isEmpty, let price = priceService.currentPrice(for: h.symbol) else { return nil }
            let m       = h.lotMultiplier
            let dir     = h.pnlDirection
            let mv      = lots.reduce(Decimal(0)) { $0 + $1.equityContribution(at: price, multiplier: m, pnlDirection: dir) }
            let basis   = lots.reduce(Decimal(0)) { $0 + ($1.remainingQty * $1.splitAdjustedCostBasisPerShare * m).rounded(to: 2) }
            let pnl     = lots.reduce(Decimal(0)) { $0 + $1.unrealizedPnL(at: price, multiplier: m) * dir }
            let pct     = basis > 0 ? (pnl / basis * 100).rounded(to: 2) : 0
            let dayPct  = (priceService.dailyChangePercent(for: h.symbol) ?? 0) * dir
            return HoldingPnLRow(id: h.id, symbol: h.symbol, name: h.name,
                                 assetType: h.assetType, marketValue: mv,
                                 unrealizedPnL: pnl, unrealizedPct: pct, todayChangePct: dayPct)
        }
        .sorted { abs($0.unrealizedPnL) > abs($1.unrealizedPnL) }
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
            .navigationTitle("P&L")
            .navigationBarTitleDisplayMode(.large)
        }
        .task(id: selectedRange) {
            await loadChartData()
        }
        .onAppear {
            // Re-fetch if chart is empty (e.g. returning to tab after API key was set)
            if chartData.isEmpty {
                histService.clearCache()
                Task { await loadChartData() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .finnhubKeyDidChange)) { _ in
            histService.clearCache()
            Task { await loadChartData() }
        }
    }

    // MARK: - Scroll Content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                TaxProfileBannerView()
                    .environmentObject(taxProfileManager)
                summaryStrip
                chartCard
                if !holdingRows.isEmpty {
                    holdingsCard
                }
                if !realizedTradeRows.isEmpty {
                    realizedTradesCard
                }
                if let taxEst = yearTaxEstimate {
                    taxYearSummaryCard(taxEst)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            histService.clearCache()
            await loadChartData()
        }
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            pnlTile(label: "UNREALIZED",
                    value: unrealizedPnL.asCurrencyCompact,
                    pct: unrealizedPnLPct,
                    isPositive: unrealizedPnL >= 0)
            pnlTile(label: "REALIZED YTD",
                    value: realizedPnLThisYear.asCurrencyCompact,
                    pct: realizedPnLPct,
                    isPositive: realizedPnLThisYear >= 0)
            pnlTile(label: "TODAY P&L",
                    value: todayChange.asCurrencyCompact,
                    pct: todayChangePct,
                    isPositive: todayChange >= 0)
        }
    }

    private func pnlTile(label: String, value: String, pct: Decimal?, isPositive: Bool) -> some View {
        let color: Color = Color.pnlColor(isPositive ? Decimal(1) : Decimal(-1))
        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppFont.statLabel)
                .foregroundColor(.textMuted)
                .kerning(0.5)
            Text(value)
                .font(AppFont.statValue)
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let pct {
                Text(pct.asPercentSigned())
                    .font(AppFont.mono(10, weight: .medium))
                    .foregroundColor(color.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statTileStyle()
    }

    // MARK: - Chart Card

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: current value + change
            VStack(alignment: .leading, spacing: 4) {
                Text(totalPortfolioValue.asCurrencyCompact)
                    .font(AppFont.mono(26, weight: .bold))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 6) {
                    Image(systemName: unrealizedPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(unrealizedPnL.asCurrencySigned) all-time")
                        .font(AppFont.mono(12, weight: .semibold))
                    if let pct = unrealizedPnLPct {
                        Text("(\(pct.asPercentSigned()))")
                            .font(AppFont.body(12))
                    }
                }
                .foregroundColor(Color.pnlColor(unrealizedPnL))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Chart
            chartBody
                .frame(height: 200)
                .padding(.horizontal, 12)

            // Range picker
            rangePicker
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)

            // Legend
            HStack(spacing: 16) {
                legendDot(color: chartLineColor, label: "Portfolio Value")
                legendDot(color: .textMuted, label: "Cost Basis", dashed: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .cardStyle()
    }

    @ViewBuilder
    private var chartBody: some View {
        if histService.isLoading && chartData.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.surfaceAlt)
                ProgressView()
                    .tint(.textSub)
            }
        } else if chartData.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.surfaceAlt)
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 28))
                        .foregroundColor(.textMuted)
                    Text("No price history available")
                        .font(AppFont.body(13))
                        .foregroundColor(.textMuted)
                    Text("Add a Finnhub API key in Settings to enable full chart history")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        } else {
            Chart {
                // Area fill
                ForEach(chartData) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [chartLineColor.opacity(0.25), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                // Portfolio value line
                ForEach(chartData) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(chartLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }
                // Cost basis reference line
                RuleMark(y: .value("Cost Basis", costBasisDouble))
                    .foregroundStyle(Color.textMuted.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                // Selected point crosshair
                if let sel = selectedPoint {
                    RuleMark(x: .value("Selected", sel.date))
                        .foregroundStyle(Color.textSub.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .center) {
                            VStack(spacing: 2) {
                                Text(sel.value, format: .currency(code: "USD").precision(.fractionLength(0)))
                                    .font(AppFont.mono(11, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text(sel.date, format: .dateTime.month(.abbreviated).day())
                                    .font(AppFont.body(10))
                                    .foregroundColor(.textMuted)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
            .chartYScale(domain: chartYMin...chartYMax)
            .chartXAxis {
                AxisMarks(values: .stride(by: xAxisStride)) { value in
                    AxisValueLabel(format: xAxisFormat, centered: false)
                        .font(AppFont.body(9))
                        .foregroundStyle(Color.textMuted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Decimal.from(v).asCurrencyCompact)
                                .font(AppFont.mono(9))
                                .foregroundColor(.textMuted)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        HStack(spacing: 4) {
            ForEach(TimeRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    Text(range.rawValue)
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(selectedRange == range ? .white : .textSub)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedRange == range
                                ? Color.appBlue
                                : Color.surfaceAlt
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - X-Axis Formatting

    private var xAxisStride: Calendar.Component {
        switch selectedRange {
        case .oneWeek:     return .day
        case .oneMonth:    return .weekOfYear
        case .threeMonths: return .month
        case .ytd:         return .month
        case .oneYear:     return .month
        case .all:         return .year
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .oneWeek:     return .dateTime.day()
        case .oneMonth:    return .dateTime.month(.abbreviated).day()
        case .threeMonths: return .dateTime.month(.abbreviated)
        case .ytd:         return .dateTime.month(.abbreviated)
        case .oneYear:     return .dateTime.month(.abbreviated)
        case .all:         return .dateTime.year()
        }
    }

    // MARK: - Holdings P&L Card

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OPEN POSITIONS")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(holdingRows) { row in
                HStack(spacing: 12) {
                    // Symbol + type dot
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(row.assetType.chipColor.color)
                                .frame(width: 6, height: 6)
                            Text(row.symbol)
                                .font(AppFont.mono(13, weight: .bold))
                                .foregroundColor(.textPrimary)
                        }
                        Text(row.name)
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 80, alignment: .leading)

                    Spacer()

                    // Market value
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("VALUE")
                            .font(AppFont.mono(8))
                            .foregroundColor(.textMuted)
                        Text(row.marketValue.asCurrencyCompact)
                            .font(AppFont.mono(12, weight: .medium))
                            .foregroundColor(.textPrimary)
                    }

                    // Unrealized P&L
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("UNRLZD")
                            .font(AppFont.mono(8))
                            .foregroundColor(.textMuted)
                        Text(row.unrealizedPnL.asCurrencyCompact)
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(Color.pnlColor(row.unrealizedPnL))
                        Text(row.unrealizedPct.asPercentSigned())
                            .font(AppFont.mono(10))
                            .foregroundColor(Color.pnlColor(row.unrealizedPnL).opacity(0.75))
                    }

                    // Today
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("TODAY")
                            .font(AppFont.mono(8))
                            .foregroundColor(.textMuted)
                        Text(row.todayChangePct.asPercentSigned())
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(Color.pnlColor(row.todayChangePct))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)

                if row.id != holdingRows.last?.id {
                    Divider()
                        .background(Color.appBorder)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 8)
        }
        .cardStyle()
    }

    // MARK: - Realized Trades Card

    private var realizedTradesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    realizedCardCollapsed.toggle()
                }
            } label: {
                HStack {
                    Text("REALIZED TRADES YTD")
                        .sectionTitleStyle()
                    Spacer()
                    Text("\(realizedTradeRows.count) trade\(realizedTradeRows.count == 1 ? "" : "s")")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                    Image(systemName: realizedCardCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 4)

            if !realizedCardCollapsed {
                ForEach(Array(consolidatedTradeRows.enumerated()), id: \.element.id) { index, row in

                VStack(spacing: 0) {
                    // Consolidated header row
                    Button {
                        if row.tradeCount > 1 {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expandedTradeSymbols.contains(row.symbol) {
                                    expandedTradeSymbols.remove(row.symbol)
                                } else {
                                    expandedTradeSymbols.insert(row.symbol)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(row.assetType.chipColor.color)
                                        .frame(width: 6, height: 6)
                                    Text(row.symbol)
                                        .font(AppFont.mono(13, weight: .bold))
                                        .foregroundColor(.textPrimary)
                                    if row.tradeCount > 1 {
                                        Text("\(row.tradeCount) trades")
                                            .font(AppFont.mono(9))
                                            .foregroundColor(.textMuted)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.surfaceAlt)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(row.netPnL.asCurrencySigned)
                                    .font(AppFont.mono(12, weight: .semibold))
                                    .foregroundColor(Color.pnlColor(row.netPnL))
                                if let pct = row.netPct {
                                    Text(pct.asPercentSigned())
                                        .font(AppFont.mono(10))
                                        .foregroundColor(Color.pnlColor(row.netPnL).opacity(0.75))
                                }
                            }
                            if row.tradeCount > 1 {
                                Image(systemName: expandedTradeSymbols.contains(row.symbol) ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.textMuted)
                                    .frame(width: 16)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)

                    // Expanded individual trades
                    if row.tradeCount > 1 && expandedTradeSymbols.contains(row.symbol) {
                        VStack(spacing: 0) {
                            ForEach(Array(row.trades.enumerated()), id: \.element.id) { tIdx, trade in
                                HStack(spacing: 10) {
                                    Text(trade.actionLabel)
                                        .font(AppFont.mono(9, weight: .bold))
                                        .foregroundColor(trade.actionColor)
                                        .frame(width: 30, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(trade.quantity.asQuantity(maxDecimalPlaces: 4)) \(trade.isOption ? "contracts" : "sh") @ \(trade.pricePerShare.asCurrency)")
                                            .font(AppFont.mono(10))
                                            .foregroundColor(.textSub)
                                        Text(trade.tradeDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                            .font(AppFont.body(9))
                                            .foregroundColor(.textMuted)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(trade.realizedPnL.asCurrencySigned)
                                            .font(AppFont.mono(11, weight: .medium))
                                            .foregroundColor(Color.pnlColor(trade.realizedPnL))
                                        if let pct = trade.realizedPct {
                                            Text(pct.asPercentSigned())
                                                .font(AppFont.mono(9))
                                                .foregroundColor(Color.pnlColor(trade.realizedPnL).opacity(0.75))
                                        }
                                    }
                                }
                                .padding(.leading, 36)
                                .padding(.trailing, 20)
                                .padding(.vertical, 8)
                                .background(Color.surfaceAlt.opacity(0.5))

                                if tIdx < row.trades.count - 1 {
                                    Divider()
                                        .background(Color.appBorder)
                                        .padding(.leading, 36)
                                }
                            }
                        }
                    }
                }

                if index < consolidatedTradeRows.count - 1 {
                    Divider()
                        .background(Color.appBorder)
                        .padding(.horizontal, 20)
                }
            }
            Spacer().frame(height: 8)
            }   // end if !realizedCardCollapsed
        }
        .cardStyle()
    }

    // MARK: - Tax Year Summary Card

    @ViewBuilder
    private func taxYearSummaryCard(_ est: TaxEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("EST. TAX YEAR SUMMARY ~")
                    .sectionTitleStyle()
                Spacer()
                Text(taxProfileManager.profile.shortLabel)
                    .font(AppFont.mono(9))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // LT / ST breakdown
            HStack(spacing: 0) {
                taxSummaryColumn(label: "LT Gains", value: ltRealizedPnL, color: .appGreen)
                Divider().background(Color.appBorder).frame(width: 1)
                taxSummaryColumn(label: "ST Gains", value: stRealizedPnL, color: .appGold)
            }
            .frame(height: 62)
            .background(Color.appBg)

            Divider().background(Color.appBorder)

            // Tax rows
            VStack(spacing: 0) {
                taxYearRow("Federal ~",     est.federalTax, est.federalRate)
                Divider().background(Color.appBorder).padding(.leading, 20)
                taxYearRow("NIIT 3.8% ~",  est.niit, nil, dim: est.niit == 0)
                if est.stateTax > 0 {
                    Divider().background(Color.appBorder).padding(.leading, 20)
                    taxYearRow("\(taxProfileManager.profile.state ?? "State") ~", est.stateTax, est.stateRate)
                }
                if est.cityTax > 0 {
                    Divider().background(Color.appBorder).padding(.leading, 20)
                    taxYearRow("City ~", est.cityTax, est.cityRate)
                }
            }

            Divider().background(Color.appBorder)

            // Totals
            HStack {
                Text("Est. Total Tax ~")
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(est.totalTax.asCurrency)
                    .font(AppFont.mono(13, weight: .bold))
                    .foregroundColor(.appRed)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if est.amtWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appGold)
                    Text("Gains may trigger AMT — consult a tax professional.")
                        .font(AppFont.body(11))
                        .foregroundColor(.appGold)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            // Tier 1 disclaimer
            Text("~ \(TaxDisclaimer.tier1) · \(taxProfileManager.profile.shortLabel)")
                .font(AppFont.body(10))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .cardStyle()
    }

    private func taxSummaryColumn(label: String, value: Decimal, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(AppFont.mono(9, weight: .semibold))
                .foregroundColor(.textMuted)
            Text(value >= 0 ? value.asCurrency : "—")
                .font(AppFont.mono(14, weight: .bold))
                .foregroundColor(value > 0 ? color : .textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private func taxYearRow(_ label: String, _ amount: Decimal, _ rate: Decimal?, dim: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(AppFont.mono(11))
                .foregroundColor(dim ? .textMuted : .textSub)
            if let r = rate, r > 0 {
                Text("(\(r.asPercent()))")
                    .font(AppFont.mono(10))
                    .foregroundColor(.textMuted)
            }
            Spacer()
            Text(amount == 0 ? "—" : amount.asCurrency)
                .font(AppFont.mono(11, weight: .medium))
                .foregroundColor(dim ? .textMuted : .textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - Legend

    private func legendDot(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(color)
                            .frame(width: 4, height: 1.5)
                    }
                }
                .frame(width: 16)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 16, height: 2)
            }
            Text(label)
                .font(AppFont.body(11))
                .foregroundColor(.textMuted)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 52))
                .foregroundColor(.textMuted)
            Text("No Holdings Yet")
                .font(AppFont.body(18, weight: .semibold))
                .foregroundColor(.textPrimary)
            Text("Add holdings to track P&L over time.")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - Chart Data Loading

    private func loadChartData() async {
        let nonCashLots = allOpenLots.filter { holdingMap[$0.holdingId]?.assetType != .cash }
        guard !nonCashLots.isEmpty else { chartData = []; return }

        let days = selectedRange.days(earliestDate: earliestLotDate)
        let symbols: [(symbol: String, source: PriceSource)] = holdings
            .filter { $0.assetType != .cash }
            .map { (symbol: $0.symbol, source: $0.priceSource) }

        let priceHistory = await histService.fetchHistory(symbols: symbols, days: days)

        // Fallback: if no history but current prices exist, synthesize cost basis → current value
        if priceHistory.isEmpty {
            let map = holdingMap
            let today = Date()
            let rangeStart = Calendar.current.date(byAdding: .day, value: -days, to: today) ?? today
            let currentValue = nonCashLots.reduce(0.0) { sum, lot in
                guard let h = map[lot.holdingId],
                      let price = priceService.currentPrice(for: h.symbol) else { return sum }
                let qty        = Double(truncating: lot.remainingQty as NSDecimalNumber)
                let multiplier = h.isOption ? 100.0 : 1.0
                if h.isShortPosition {
                    let cb = Double(truncating: lot.splitAdjustedCostBasisPerShare as NSDecimalNumber)
                    return sum + (cb - Double(truncating: price as NSDecimalNumber)) * qty * multiplier
                }
                return sum + qty * Double(truncating: price as NSDecimalNumber) * multiplier
            }
            let costBasisValue = nonCashLots.reduce(0.0) { sum, lot in
                guard let h = map[lot.holdingId] else { return sum }
                let qty        = Double(truncating: lot.remainingQty as NSDecimalNumber)
                let cb         = Double(truncating: lot.splitAdjustedCostBasisPerShare as NSDecimalNumber)
                let multiplier = h.isOption ? 100.0 : 1.0
                return sum + qty * cb * multiplier
            }
            if currentValue > 0 {
                chartData = [
                    PortfolioDataPoint(date: rangeStart, value: costBasisValue > 0 ? costBasisValue : currentValue),
                    PortfolioDataPoint(date: today, value: currentValue)
                ]
            }
            return
        }

        // Build date spine — union of all dates across all symbols' histories
        let allDates = Set(priceHistory.values.flatMap { $0.map(\.date) }).sorted()
        guard !allDates.isEmpty else { return }

        let map = holdingMap
        let points: [PortfolioDataPoint] = allDates.map { date in
            let value = allOpenLots.reduce(0.0) { sum, lot in
                guard let h = map[lot.holdingId], h.assetType != .cash,
                      let history = priceHistory[h.symbol.uppercased()],
                      let price = history.price(on: date) else { return sum }
                let qty = Double(truncating: lot.remainingQty as NSDecimalNumber)
                let multiplier: Double = h.isOption ? 100 : 1
                let costBasis = Double(truncating: lot.splitAdjustedCostBasisPerShare as NSDecimalNumber)
                if h.isShortPosition {
                    // Short: net equity = (costBasis − currentPrice) × qty × 100
                    return sum + (costBasis - price) * qty * multiplier
                }
                return sum + qty * price * multiplier
            }
            return PortfolioDataPoint(date: date, value: value)
        }
        .filter { $0.value > 0 }

        chartData = points
    }
}

// MARK: - AppChipColor → Color helper (used in holdingRows)

private extension AppChipColor {
    var color: Color {
        switch self {
        case .blue:   return .chipStock
        case .teal:   return .chipETF
        case .gold:   return .chipCrypto
        case .purple: return .chipOption
        case .slate:  return .chipTreasury
        case .green:  return .appGreen
        }
    }
}

// MARK: - Preview

#Preview {
    PnLView()
        .environmentObject(PriceService())
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
