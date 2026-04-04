import SwiftUI
import CoreData

struct HoldingsListView: View {

    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var priceService: PriceService
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .default)
    private var holdings: FetchedResults<Holding>

    @State private var selectedFilter: AssetType? = nil  // nil = All
    @State private var showAddHolding = false
    @State private var showDepositCash = false
    @State private var showWithdrawCash = false
    @State private var holdingToDelete: Holding?

    // MARK: - Filtered Holdings

    private var filteredHoldings: [Holding] {
        let base = selectedFilter.map { f in holdings.filter { $0.assetType == f } }
                   ?? Array(holdings)
        return base.filter { holding in
            let lots = (try? context.fetch(Lot.openLots(for: holding.id))) ?? []
            return lots.reduce(Decimal(0)) { $0 + $1.remainingQty } > 0
        }
    }

    // MARK: - Grouped Holdings

    private var groupedByType: [(AssetType, [Holding])] {
        let order: [AssetType] = [.stock, .etf, .crypto, .options, .treasury, .cash]
        return order.compactMap { type in
            let group = filteredHoldings.filter { $0.assetType == type }
            return group.isEmpty ? nil : (type, group)
        }
    }

    // MARK: - Portfolio Summary

    private var totalValue: Decimal {
        filteredHoldings.reduce(Decimal(0)) { sum, h in
            guard let price = priceService.currentPrice(for: h.symbol) else { return sum }
            let lots = (try? context.fetch(Lot.openLots(for: h.id))) ?? []
            let qty = lots.reduce(Decimal(0)) { $0 + $1.remainingQty }
            return sum + (qty * price * h.lotMultiplier).rounded(to: 2)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Filter chips
                    filterChips
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    if holdings.isEmpty {
                        emptyState
                    } else if filteredHoldings.isEmpty {
                        noResultsState
                    } else {
                        holdingsList
                    }
                }
            }
            .navigationTitle("Holdings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        Menu {
                            Button {
                                showDepositCash = true
                            } label: {
                                Label("Deposit Cash", systemImage: "plus.circle")
                            }
                            Button {
                                showWithdrawCash = true
                            } label: {
                                Label("Withdraw Cash", systemImage: "minus.circle")
                            }
                        } label: {
                            Image(systemName: "dollarsign.circle")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.appBlue)
                        }
                        .accessibilityLabel("Cash actions")
                        Button {
                            showAddHolding = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.appBlue)
                        }
                        .accessibilityLabel("Add holding")
                    }
                }
            }
            .sheet(isPresented: $showAddHolding) {
                AddHoldingView()
                    .environment(\.managedObjectContext, context)
            }
            .sheet(isPresented: $showDepositCash) {
                DepositCashView()
                    .environment(\.managedObjectContext, context)
            }
            .sheet(isPresented: $showWithdrawCash) {
                WithdrawCashView(availableBalance: CashLedgerService.availableBalance(in: context))
                    .environment(\.managedObjectContext, context)
            }
            .task {
                await priceService.refreshAllPrices(holdings: Array(holdings))
                priceService.startAutoRefresh(holdings: Array(holdings))
            }
            .onDisappear {
                priceService.stopAutoRefresh()
            }
            .refreshable {
                await priceService.refreshAllPrices(holdings: Array(holdings))
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isSelected: selectedFilter == nil) {
                    selectedFilter = nil
                }
                ForEach(AssetType.allCases.filter { $0 != .cash }, id: \.self) { type in
                    FilterChip(
                        label: type.displayName,
                        color: chipColor(type),
                        isSelected: selectedFilter == type
                    ) {
                        selectedFilter = selectedFilter == type ? nil : type
                    }
                }
            }
        }
    }

    // MARK: - Holdings List

    private var showDeleteAlert: Binding<Bool> {
        Binding(
            get: { holdingToDelete != nil },
            set: { if !$0 { holdingToDelete = nil } }
        )
    }

    private var deleteAlertMessage: String {
        let symbol = holdingToDelete?.symbol ?? ""
        return "This will remove \(symbol) and all its lots. This action cannot be undone."
    }

    private var holdingsList: some View {
        listContent
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .alert("Delete Holding", isPresented: showDeleteAlert) {
                Button("Cancel", role: .cancel) { holdingToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let h = holdingToDelete { deleteHolding(h) }
                }
            } message: {
                Text(deleteAlertMessage)
            }
    }

    private var listContent: some View {
        List {
            ForEach(groupedByType, id: \.0) { type, groupHoldings in
                Section {
                    ForEach(groupHoldings) { holding in
                        holdingRow(holding)
                    }
                } header: {
                    Text(type.pluralName)
                        .sectionTitleStyle()
                        .padding(.leading, -16)
                }
            }
        }
    }

    private func holdingRow(_ holding: Holding) -> some View {
        NavigationLink(destination: holding.isTreasury
            ? AnyView(TreasuryDetailView(holding: holding))
            : AnyView(PositionDetailView(holding: holding))
        ) {
            HoldingRowView(holding: holding)
        }
        .listRowBackground(Color.surface)
        .listRowSeparatorTint(Color.appBorder)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                holdingToDelete = holding
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "briefcase")
                .font(.system(size: 52))
                .foregroundColor(.textMuted)
            VStack(spacing: 8) {
                Text("No Holdings Yet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("Tap + to add your first position")
                    .font(.system(size: 14))
                    .foregroundColor(.textSub)
            }
            Button {
                showAddHolding = true
            } label: {
                Label("Add Holding", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.appBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .padding()
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundColor(.textMuted)
            Text("No \(selectedFilter?.fullName ?? "") positions")
                .font(.system(size: 15))
                .foregroundColor(.textSub)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func chipColor(_ type: AssetType) -> Color {
        switch type.chipColor {
        case .blue:   return .appBlue
        case .teal:   return .appTeal
        case .gold:   return .appGold
        case .purple: return .appPurple
        case .green:  return .appGreen
        case .slate:  return Color(hex: "#94A3B8")
        }
    }

    private func deleteHolding(_ holding: Holding) {
        let symbol = holding.symbol
        context.delete(holding)
        try? context.save()
        holdingToDelete = nil
        DynamicGraphService.shared.remove(symbol: symbol)
    }
}

// MARK: - Holding Row View

struct HoldingRowView: View {
    let holding: Holding
    @EnvironmentObject private var priceService: PriceService
    @FetchRequest private var lots: FetchedResults<Lot>

    init(holding: Holding) {
        self.holding = holding
        _lots = FetchRequest(fetchRequest: Lot.openLots(for: holding.id), animation: .none)
    }

    private var openLots: [Lot] { Array(lots) }

    private var totalQty: Decimal {
        openLots.reduce(0) { $0 + $1.remainingQty }
    }

    private var totalCostBasis: Decimal {
        openLots.reduce(0) { $0 + $1.totalCostBasis }
    }

    private var avgCostPerShare: Decimal {
        guard totalQty > 0 else { return 0 }
        // For options, totalCostBasis includes ×100 multiplier; divide by totalQty×100 to get premium per share.
        let shares = holding.isOption ? totalQty * 100 : totalQty
        return (totalCostBasis / shares).rounded(to: 4)
    }

    private var priceData: PriceData? {
        priceService.price(for: holding.symbol)
    }

    private var marketValue: Decimal? {
        guard let price = priceData?.currentPrice else { return nil }
        return (totalQty * price).rounded(to: 2)
    }

    private var unrealizedPnL: Decimal? {
        guard let mv = marketValue else { return nil }
        return (mv - totalCostBasis).rounded(to: 2)
    }

    private var unrealizedPnLPercent: Decimal? {
        guard let pnl = unrealizedPnL, totalCostBasis > 0 else { return nil }
        return ((pnl / totalCostBasis) * 100).rounded(to: 2)
    }

    private var accessibilityDescription: String {
        var parts = ["\(holding.name), \(holding.assetType.displayName)"]
        if holding.isOption {
            let dir = holding.isShortPosition ? "short" : "long"
            parts.append("\(dir), \(totalQty.asQuantity(maxDecimalPlaces: 0)) contracts at \(avgCostPerShare.asCurrency)")
        } else if let mv = marketValue, let pnl = unrealizedPnL {
            let direction = pnl >= 0 ? "up" : "down"
            parts.append("value \(mv.asCurrency), \(direction) \(pnl.asCurrencySigned)")
        } else {
            parts.append("cost basis \(totalCostBasis.asCurrency)")
        }
        if holding.isOptionExpired { parts.append("expired") }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        HStack(spacing: 12) {
            symbolColumn
            Spacer()
            priceColumn
        }
        .padding(.vertical, 4)
        .opacity(holding.isOptionExpired ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbolColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(holding.symbol)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.textPrimary)
                AssetTypeChip(type: holding.assetType)
                if holding.isDRIPEnabled {
                    SmallChip(label: "DRIP", color: .appGreen)
                }
                if holding.isOptionExpired {
                    SmallChip(label: "EXP", color: .appRed)
                }
                if holding.isOption && holding.isShortPosition {
                    SmallChip(label: "STO", color: .appPurple)
                }
            }
            Text(holding.name)
                .font(.system(size: 12))
                .foregroundColor(.textSub)
                .lineLimit(1)
        }
    }

    private var priceColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if holding.isOption {
                optionPriceColumn
            } else {
                valueText
                pnlText
                freshnessIndicator
            }
        }
    }

    @ViewBuilder
    private var optionPriceColumn: some View {
        // Premium received (STO) or paid (BTO)
        let premiumLabel = holding.isShortPosition ? "STO" : "BTO"
        Text("\(premiumLabel) \(avgCostPerShare.asCurrency)")
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundColor(.textPrimary)
        // Strike price
        if let strike = holding.strikePrice {
            Text("Strike \(strike.asCurrency)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSub)
        }
        // Contracts count
        Text("\(totalQty.asQuantity(maxDecimalPlaces: 0)) contract\(totalQty == 1 ? "" : "s")")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.textMuted)
    }

    @ViewBuilder
    private var valueText: some View {
        if let mv = marketValue {
            Text(mv.asCurrency)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
        } else {
            Text(totalCostBasis.asCurrency)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
        }
    }

    @ViewBuilder
    private var pnlText: some View {
        if let pnl = unrealizedPnL, let pct = unrealizedPnLPercent {
            HStack(spacing: 4) {
                Text(pnl.asCurrencySigned)
                Text("(\(pct.asPercentSigned()))")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color.pnlColor(pnl))
        } else {
            Text("\(totalQty.asQuantity(maxDecimalPlaces: 4)) shares")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSub)
        }
    }

    @ViewBuilder
    private var freshnessIndicator: some View {
        if let pd = priceData, pd.isStale {
            HStack(spacing: 3) {
                Circle().fill(Color.appGold).frame(width: 5, height: 5)
                Text("\(pd.fetchedAt.minutesSince)m ago")
                    .font(.system(size: 9))
                    .foregroundColor(.appGold)
            }
        } else if let pd = priceData, pd.isLive {
            HStack(spacing: 3) {
                Circle().fill(Color.appGreen).frame(width: 5, height: 5)
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.appGreen)
            }
        }
    }
}

// MARK: - Chip Components

struct AssetTypeChip: View {
    let type: AssetType

    var color: Color {
        switch type.chipColor {
        case .blue:   return .appBlue
        case .teal:   return .appTeal
        case .gold:   return .appGold
        case .purple: return .appPurple
        case .green:  return .appGreen
        case .slate:  return Color(hex: "#94A3B8")
        }
    }

    var body: some View {
        Text(type.displayName)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.3), lineWidth: 0.5)
            )
    }
}

struct SmallChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct FilterChip: View {
    let label: String
    var color: Color = .appBlue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? color : .textSub)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? color.opacity(0.12) : Color.surface)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color.opacity(0.4) : Color.appBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "Tap to show all" : "Filter by \(label)")
    }
}

// MARK: - Preview

#Preview {
    HoldingsListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environmentObject(PriceService())
        .environmentObject(NetworkMonitor())
}
