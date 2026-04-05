import SwiftUI
import CoreData

/// Position-level sell sheet — choose a lot method and quantity,
/// and the app selects lots automatically (FIFO / LIFO / Highest / Lowest / Specific).
struct SellPositionSheet: View {

    let holding: Holding
    let lots:    [Lot]
    /// Called after a successful save with the new Transaction and a lot snapshot for undo.
    var onCompleted: ((Transaction, (id: UUID, remainingQty: Decimal, isClosed: Bool)) -> Void)?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss)              private var dismiss
    @EnvironmentObject private var taxProfileManager: TaxProfileManager

    // MARK: - Form State

    @State private var lotMethod:   LotMethod = .fifo
    @State private var quantityStr: String    = ""
    @State private var sliderFraction: Double  = 1.0

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderFraction },
            set: { v in
                sliderFraction = v
                let raw = Decimal(v) * totalAvailableQty
                quantityStr = raw.rounded(to: 4).asQuantity(maxDecimalPlaces: 4)
            }
        )
    }
    @State private var priceStr:    String    = ""
    @State private var feeStr:      String    = ""
    @State private var closeDate:   Date      = Date()
    @State private var showDatePicker          = false
    @State private var specificLot: Lot?

    // MARK: - Validation
    @State private var showError    = false
    @State private var errorMessage = ""
    @State private var isSaving     = false

    // MARK: - Computed

    private var contractMultiplier: Decimal { holding.isOption ? 100 : 1 }
    private var isBTC: Bool { holding.isOption && holding.isShortPosition }

    private var totalAvailableQty: Decimal {
        lots.reduce(0) { $0 + $1.remainingQty }
    }

    private var closeQty: Decimal? { Decimal.from(quantityStr) }
    private var price:    Decimal? { Decimal.from(priceStr)    }
    private var fee:      Decimal  { Decimal.from(feeStr) ?? 0 }

    /// Lots sorted by the selected method for sequential consumption.
    private var sortedLots: [Lot] {
        switch lotMethod {
        case .fifo:        return lots.sorted { $0.purchaseDate < $1.purchaseDate }
        case .lifo:        return lots.sorted { $0.purchaseDate > $1.purchaseDate }
        case .highestCost: return lots.sorted { $0.splitAdjustedCostBasisPerShare > $1.splitAdjustedCostBasisPerShare }
        case .lowestCost:  return lots.sorted { $0.splitAdjustedCostBasisPerShare < $1.splitAdjustedCostBasisPerShare }
        case .specificLot:
            guard let chosen = specificLot else { return lots.sorted { $0.purchaseDate < $1.purchaseDate } }
            return [chosen]
        }
    }

    /// Lot allocations for the requested quantity.
    private var allocations: [(lot: Lot, qty: Decimal)] {
        guard let qty = closeQty, qty > 0 else { return [] }
        var remaining = qty
        var result: [(lot: Lot, qty: Decimal)] = []
        for lot in sortedLots {
            guard remaining > 0 else { break }
            let take = min(lot.remainingQty, remaining)
            result.append((lot: lot, qty: take))
            remaining -= take
        }
        return result
    }

    private var totalRealizedPnL: Decimal? {
        guard let p = price else { return nil }
        let m = contractMultiplier
        return allocations.reduce(Decimal(0)) { sum, alloc in
            let cost = (alloc.qty * alloc.lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
            let proceeds = (alloc.qty * p * m).rounded(to: 2)
            return sum + (isBTC ? (cost - proceeds) : (proceeds - cost))
        }.rounded(to: 2)
    }

    private var canSave: Bool {
        guard let qty = closeQty, let p = price else { return false }
        guard qty > 0 && qty <= totalAvailableQty && p >= 0 else { return false }
        if lotMethod == .specificLot { return specificLot != nil }
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        TaxProfileBannerView()
                            .environmentObject(taxProfileManager)
                        methodCard
                        quantityCard
                        priceCard
                        if !allocations.isEmpty {
                            allocationCard
                        }
                        saveButton
                    }
                    .padding(16)
                }
            }
            .navigationTitle(holding.isOption ? (isBTC ? "Buy to Close" : "Sell to Close") : (holding.assetType == .cash ? "Withdraw Cash" : "Sell Position"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
            }
            .alert("Check Your Inputs", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                quantityStr = totalAvailableQty.asQuantity(maxDecimalPlaces: 4)
            }
        }
    }

    // MARK: - Lot Method Card

    private var methodCard: some View {
        FormCard(title: "LOT METHOD") {
            VStack(spacing: 0) {
                ForEach(LotMethod.allCases, id: \.self) { method in
                    Button {
                        lotMethod = method
                        if method != .specificLot { specificLot = nil }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: lotMethod == method ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundColor(lotMethod == method ? .appBlue : .textMuted)
                            Text(method.displayName)
                                .font(AppFont.body(14))
                                .foregroundColor(lotMethod == method ? .textPrimary : .textSub)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if method != LotMethod.allCases.last {
                        Divider().background(Color.appBorder)
                    }
                }

                if lotMethod == .specificLot {
                    Divider().background(Color.appBorder)
                    specificLotPicker
                }
            }
        }
    }

    private var specificLotPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SELECT LOT")
                .font(AppFont.mono(10, weight: .bold))
                .foregroundColor(.textMuted)
                .kerning(0.5)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            ForEach(lots.sorted { $0.purchaseDate < $1.purchaseDate }) { lot in
                Button {
                    specificLot = lot
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: specificLot?.id == lot.id ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundColor(specificLot?.id == lot.id ? .appBlue : .textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lot #\(lot.lotNumber) · \(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(AppFont.mono(12, weight: .medium))
                                .foregroundColor(.textPrimary)
                            Text("\(lot.remainingQty.asQuantity(maxDecimalPlaces: 4)) \(holding.isOption ? "contracts" : "shares") @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                                .font(AppFont.mono(11))
                                .foregroundColor(.textSub)
                        }
                        Spacer()
                        SmallChip(label: lot.isLongTerm ? "LT" : "ST",
                                  color: lot.isLongTerm ? .appGreen : .textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Quantity Card

    private var quantityCard: some View {
        FormCard(title: holding.isOption ? "CONTRACTS TO CLOSE" : "SHARES TO SELL") {
            VStack(spacing: 8) {
                HStack {
                    Text("Available: \(totalAvailableQty.asQuantity(maxDecimalPlaces: 4))")
                        .font(AppFont.body(12))
                        .foregroundColor(.textMuted)
                    Spacer()
                    if let qty = closeQty, qty > 0 {
                        Text(qty == totalAvailableQty ? "Full position" : "Partial sell")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(qty == totalAvailableQty ? .appGreen : .appBlue)
                    }
                }

                Slider(value: sliderBinding, in: 0...1)
                    .tint(.appBlue)

                TextField(totalAvailableQty.asQuantity(maxDecimalPlaces: 4), text: $quantityStr)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.textPrimary)
                    .onChange(of: quantityStr) { _, v in
                        if let qty = Decimal.from(v), totalAvailableQty > 0 {
                            sliderFraction = min(max(NSDecimalNumber(decimal: qty / totalAvailableQty).doubleValue, 0), 1)
                        }
                    }
            }
        }
    }

    // MARK: - Price Card

    private var priceCard: some View {
        FormCard(title: holding.isOption ? (isBTC ? "BUY TO CLOSE" : "SELL TO CLOSE") : "SALE DETAILS") {
            VStack(spacing: 12) {
                datePickerRow(label: "Close Date", date: $closeDate, isExpanded: $showDatePicker)
                Divider().background(Color.appBorder)
                FormField(label: holding.isOption ? "Close Price / Share" : "Sell Price / Share", placeholder: "0.00") {
                    TextField("0.00", text: $priceStr)
                        .keyboardType(.decimalPad)
                }
                Divider().background(Color.appBorder)
                FormField(label: "Fee / Commission (optional)", placeholder: "0.00") {
                    TextField("0.00", text: $feeStr)
                        .keyboardType(.decimalPad)
                }
            }
        }
    }

    // MARK: - Allocation Preview Card

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LOT ALLOCATION")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(allocations.enumerated()), id: \.offset) { index, alloc in
                    let lot = alloc.lot
                    let qty = alloc.qty
                    HStack(spacing: 10) {
                        SmallChip(label: lot.isLongTerm ? "LT" : "ST",
                                  color: lot.isLongTerm ? .appGreen : .textMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lot #\(lot.lotNumber) · \(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(AppFont.mono(11, weight: .medium))
                                .foregroundColor(.textPrimary)
                            Text("\(qty.asQuantity(maxDecimalPlaces: 4)) \(holding.isOption ? "contracts" : "shares") @ \(lot.splitAdjustedCostBasisPerShare.asCurrency)")
                                .font(AppFont.mono(10))
                                .foregroundColor(.textSub)
                        }
                        Spacer()
                        if let p = price {
                            let m = contractMultiplier
                            let cost = (qty * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
                            let proceeds = (qty * p * m).rounded(to: 2)
                            let pnl = isBTC ? (cost - proceeds) : (proceeds - cost)
                            Text(pnl.asCurrencySigned)
                                .font(AppFont.mono(11, weight: .semibold))
                                .foregroundColor(Color.pnlColor(pnl))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if index < allocations.count - 1 {
                        Divider().background(Color.appBorder)
                    }
                }

                if let totalPnL = totalRealizedPnL {
                    Divider().background(Color.appBorder)
                    HStack {
                        Text("Total Realized P&L")
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Text(totalPnL.asCurrencySigned)
                            .font(AppFont.mono(12, weight: .bold))
                            .foregroundColor(Color.pnlColor(totalPnL))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .cardStyle()
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button { save() } label: {
            Group {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text(holding.isOption ? (isBTC ? "Confirm BTC" : "Confirm STC") : (holding.assetType == .cash ? "Confirm Withdrawal" : "Confirm Sale"))
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canSave ? (isBTC ? Color.appPurple : Color.appRed) : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!canSave || isSaving)
    }

    // MARK: - Save

    private func save() {
        guard let qty = closeQty, qty > 0, qty <= totalAvailableQty,
              let p = price, p >= 0 else {
            errorMessage = "Invalid quantity or price."
            showError = true
            return
        }

        isSaving = true
        let m = contractMultiplier
        var lastTx: Transaction?
        var lastSnap: (id: UUID, remainingQty: Decimal, isClosed: Bool)?

        for alloc in allocations {
            let lot = alloc.lot
            let takeQty = alloc.qty
            let txTotal: Decimal = isBTC
                ? (takeQty * p * m + fee).rounded(to: 2)
                : (takeQty * p * m - fee).rounded(to: 2)

            // Tax estimate for this lot slice
            let pnl: Decimal = isBTC
                ? ((takeQty * lot.splitAdjustedCostBasisPerShare * m) - txTotal).rounded(to: 2)
                : (txTotal - (takeQty * lot.splitAdjustedCostBasisPerShare * m)).rounded(to: 2)
            var est: TaxEstimate? = nil
            if pnl > 0 && !holding.isRetirementAccount && taxProfileManager.isProfileComplete {
                let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
                est = engine.estimate(gain: pnl, purchaseDate: lot.purchaseDate, saleDate: closeDate, isSection1256: holding.isSection1256)
            }

            let snapRemainingQty = lot.remainingQty
            let snapIsClosed     = lot.isClosed

            lot.remainingQty = (lot.remainingQty - takeQty).rounded(to: 8)
            if lot.remainingQty <= 0 {
                lot.remainingQty = 0
                lot.isClosed = true
            }

            let tx = Transaction.createSell(
                in: context,
                holdingId: holding.id,
                lotId: lot.id,
                quantity: takeQty,
                pricePerShare: p,
                fee: fee,
                tradeDate: closeDate,
                totalAmountOverride: txTotal,
                taxEstimate: est
            )
            tx.lotMethod = lotMethod

            // Track last transaction/snapshot for undo (single-lot undo for simplicity)
            lastTx   = tx
            lastSnap = (id: lot.id, remainingQty: snapRemainingQty, isClosed: snapIsClosed)
        }

        do {
            try context.save()
            // Auto-credit net proceeds to Cash (skip BTC and Cash withdrawals)
            if !isBTC && holding.assetType != .cash {
                let totalProceeds = allocations.reduce(Decimal(0)) { sum, alloc in
                    guard let p = price else { return sum }
                    let m = contractMultiplier
                    return sum + (alloc.qty * p * m - fee).rounded(to: 2)
                }
                let label = holding.isOption ? "\(holding.symbol) STC" : "\(holding.symbol) Sell"
                CashLedgerService.credit(amount: totalProceeds, date: closeDate, sourceNote: label, in: context)
                try? context.save()
            }
            if let tx = lastTx, let snap = lastSnap {
                onCompleted?(tx, snap)
            }
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
            context.rollback()
        }

        isSaving = false
    }

    // MARK: - Helpers

    @ViewBuilder
    private func datePickerRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(date.wrappedValue.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(.appBlue)
                }
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.appBlue)
                    .colorScheme(.dark)
                    .padding(.top, 4)
                    .onChange(of: date.wrappedValue) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue = false }
                    }
            }
        }
    }
}
