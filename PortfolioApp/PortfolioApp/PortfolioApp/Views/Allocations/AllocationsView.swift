import SwiftUI
import CoreData
import Charts

// MARK: - Allocations View

struct AllocationsView: View {

    @EnvironmentObject private var priceService: PriceService

    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .default)
    private var holdings: FetchedResults<Holding>

    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isClosed == NO AND isSoftDeleted == NO")
    )
    private var allOpenLots: FetchedResults<Lot>

    // MARK: - Derived Map

    private var holdingMap: [UUID: Holding] {
        Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })
    }

    // MARK: - Computed: Portfolio Value

    private var totalPortfolioValue: Decimal {
        allOpenLots.reduce(Decimal(0)) { sum, lot in
            guard let h = holdingMap[lot.holdingId] else { return sum }
            if h.isOption { return sum + lot.totalCostBasis }
            guard let price = priceService.currentPrice(for: h.symbol) else { return sum }
            return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
        }
    }

    // MARK: - Computed: Asset Type Slices

    private var assetTypeSlices: [AllocationSlice] {
        var valueByType: [AssetType: Decimal] = [:]
        for lot in allOpenLots {
            guard let h = holdingMap[lot.holdingId] else { continue }
            let contrib: Decimal
            if h.isOption {
                contrib = lot.totalCostBasis
            } else {
                guard let price = priceService.currentPrice(for: h.symbol) else { continue }
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

    // MARK: - Computed: Sector Slices

    private var sectorSlices: [SectorSlice] {
        var valueBySetor: [String: Decimal] = [:]
        for lot in allOpenLots {
            guard let h = holdingMap[lot.holdingId] else { continue }
            let contrib: Decimal
            if h.isOption {
                contrib = lot.totalCostBasis
            } else {
                guard let price = priceService.currentPrice(for: h.symbol) else { continue }
                contrib = lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
            }
            guard contrib > 0 else { continue }
            let sector = (h.sector?.isEmpty == false) ? h.sector! : "Other"
            valueBySetor[sector, default: 0] += contrib
        }
        let total = valueBySetor.values.reduce(Decimal(0), +)
        guard total > 0 else { return [] }
        let sorted = valueBySetor
            .sorted { $0.value > $1.value }
        return sorted.enumerated().map { index, pair in
            SectorSlice(
                name: pair.key,
                value: pair.value,
                percentage: Double(truncating: (pair.value / total * 100) as NSDecimalNumber),
                colorIndex: index
            )
        }
    }

    // MARK: - Computed: Holdings by Weight

    private var holdingWeights: [HoldingWeight] {
        let total = totalPortfolioValue
        guard total > 0 else { return [] }
        return holdings.compactMap { h -> HoldingWeight? in
            let mv = allOpenLots
                .filter { $0.holdingId == h.id }
                .reduce(Decimal(0)) { sum, lot in
                    if h.isOption { return sum + lot.totalCostBasis }
                    guard let price = priceService.currentPrice(for: h.symbol) else { return sum }
                    return sum + lot.equityContribution(at: price, multiplier: h.lotMultiplier, pnlDirection: h.pnlDirection)
                }
            guard mv > 0 else { return nil }
            let pct = Double(truncating: (mv / total * 100) as NSDecimalNumber)
            return HoldingWeight(id: h.id, symbol: h.symbol, name: h.name,
                                 assetType: h.assetType, marketValue: mv, weightPct: pct)
        }
        .sorted { $0.weightPct > $1.weightPct }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            if holdings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if !assetTypeSlices.isEmpty {
                            assetTypeCard
                        }
                        if sectorSlices.count > 1 {
                            sectorCard
                        }
                        if !holdingWeights.isEmpty {
                            holdingsCard
                        }
                        if !concentrationRisks.isEmpty {
                            concentrationRiskCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Allocations")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Asset Type Card

    private var assetTypeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BY ASSET TYPE")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 24) {
                Chart(assetTypeSlices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.percentage),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(3)
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(assetTypeSlices) { slice in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(slice.color)
                                .frame(width: 10, height: 10)
                            Text(slice.assetType.pluralName)
                                .font(AppFont.body(13))
                                .foregroundColor(.textSub)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f%%", slice.percentage))
                                    .font(AppFont.mono(13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text(slice.value.asCurrencyCompact)
                                    .font(AppFont.mono(10))
                                    .foregroundColor(.textMuted)
                            }
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

    // MARK: - Sector Card

    private var sectorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BY SECTOR")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            HStack(alignment: .center, spacing: 24) {
                Chart(sectorSlices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.percentage),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(slice.color)
                    .cornerRadius(3)
                }
                .frame(width: 140, height: 140)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sectorSlices) { slice in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(slice.color)
                                .frame(width: 10, height: 10)
                            Text(slice.name)
                                .font(AppFont.body(13))
                                .foregroundColor(.textSub)
                                .lineLimit(1)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f%%", slice.percentage))
                                    .font(AppFont.mono(13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text(slice.value.asCurrencyCompact)
                                    .font(AppFont.mono(10))
                                    .foregroundColor(.textMuted)
                            }
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

    // MARK: - Holdings by Weight Card

    private var holdingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HOLDINGS BY WEIGHT")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(holdingWeights) { item in
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        // Asset type color dot
                        Circle()
                            .fill(item.barColor)
                            .frame(width: 8, height: 8)

                        Text(item.symbol)
                            .font(AppFont.mono(13, weight: .bold))
                            .foregroundColor(.textPrimary)

                        Text(item.name)
                            .font(AppFont.body(12))
                            .foregroundColor(.textMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.2f%%", item.weightPct))
                                .font(AppFont.mono(13, weight: .semibold))
                                .foregroundColor(.textPrimary)
                            Text(item.marketValue.asCurrencyCompact)
                                .font(AppFont.mono(10))
                                .foregroundColor(.textMuted)
                        }
                    }

                    // Weight bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.appBorder)
                                .frame(height: 4)
                            Capsule()
                                .fill(item.barColor)
                                .frame(width: max(4, geo.size.width * item.weightPct / 100), height: 4)
                        }
                    }
                    .frame(height: 4)
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

    // MARK: - Concentration Risk

    struct ConcentrationRisk: Identifiable {
        let id = UUID()
        let upstreamSymbol: String
        let upstreamName: String
        let dependentSymbols: [String]   // held symbols that depend on it
        let combinedWeightPct: Double    // combined portfolio % of those dependents
    }

    private var concentrationRisks: [ConcentrationRisk] {
        let stockSymbols = holdingWeights
            .filter { $0.assetType == .stock || $0.assetType == .etf }
            .map { $0.symbol }
        let weightMap: [String: Double] = Dictionary(
            uniqueKeysWithValues: holdingWeights.map { ($0.symbol, $0.weightPct) }
        )

        // Map upstream → which held symbols depend on it
        var upstreamToDependents: [String: [String]] = [:]
        for symbol in stockSymbols {
            for upstream in IndustryGraphLoader.company(for: symbol)?.upstream ?? [] {
                upstreamToDependents[upstream, default: []].append(symbol)
            }
        }

        return upstreamToDependents
            .filter { $0.value.count >= 2 }
            .compactMap { upstreamSymbol, dependents in
                let combined = dependents.reduce(0.0) { $0 + (weightMap[$1] ?? 0) }
                guard combined > 5 else { return nil }  // only warn if >5% combined
                let name = IndustryGraphLoader.company(for: upstreamSymbol)?.name ?? upstreamSymbol
                return ConcentrationRisk(
                    upstreamSymbol: upstreamSymbol,
                    upstreamName: name,
                    dependentSymbols: dependents.sorted(),
                    combinedWeightPct: combined
                )
            }
            .sorted { $0.combinedWeightPct > $1.combinedWeightPct }
            .prefix(5)
            .map { $0 }
    }

    private var concentrationRiskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.appGold)
                Text("SUPPLY CHAIN CONCENTRATION RISKS")
                    .sectionTitleStyle()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(concentrationRisks.enumerated()), id: \.element.id) { index, risk in
                    if index > 0 { Divider().background(Color.appBorder) }
                    concentrationRiskRow(risk)
                }
            }
            .cardStyle()

            Text("Multiple holdings share a dependency on the same upstream company. A disruption to that supplier could affect all of them simultaneously.")
                .font(AppFont.body(11))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 4)
        }
    }

    private func concentrationRiskRow(_ risk: ConcentrationRisk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(risk.upstreamName.isEmpty ? risk.upstreamSymbol : risk.upstreamName)
                        .font(AppFont.body(13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text("\(risk.dependentSymbols.joined(separator: ", ")) all depend on \(risk.upstreamSymbol)")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f%%", risk.combinedWeightPct))
                        .font(AppFont.mono(13, weight: .bold))
                        .foregroundColor(.appGold)
                    Text("of portfolio")
                        .font(AppFont.mono(9))
                        .foregroundColor(.textMuted)
                }
            }

            // Dependent symbol chips
            HStack(spacing: 6) {
                ForEach(risk.dependentSymbols, id: \.self) { sym in
                    Text(sym)
                        .font(AppFont.mono(10, weight: .bold))
                        .foregroundColor(.appGold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.appGoldDim)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            Text("Add holdings to see allocation breakdown.")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - Sector Slice Model

struct SectorSlice: Identifiable {
    let id = UUID()
    let name: String
    let value: Decimal
    let percentage: Double
    let colorIndex: Int

    // Rotating palette — works for any set of sector names
    private static let palette: [Color] = [
        .appBlue, .appTeal, .appGreen, .appGold, .appPurple,
        Color(hex: "#F97316"), Color(hex: "#EC4899"), Color(hex: "#84CC16"),
        Color(hex: "#06B6D4"), Color(hex: "#8B5CF6"), Color(hex: "#64748B"),
        Color(hex: "#EF4444")
    ]

    var color: Color {
        // "Other" always gets the muted slate tone
        if name == "Other" { return Color(hex: "#64748B") }
        return Self.palette[colorIndex % Self.palette.count]
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AllocationsView()
            .environmentObject(PriceService())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
