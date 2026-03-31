import SwiftUI
import CoreData

struct SellLotView: View {

    let holding: Holding
    let lot: Lot
    var onCompleted: ((Transaction, (id: UUID, remainingQty: Decimal, isClosed: Bool)) -> Void)?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var taxProfileManager: TaxProfileManager

    // MARK: - Form State

    @State private var quantity: String = ""
    @State private var sliderFraction: Double = 1.0   // fraction of maxQty [0, 1]

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderFraction },
            set: { v in
                sliderFraction = v
                let raw = Decimal(v) * maxQty
                quantity = raw.rounded(to: 4).asQuantity(maxDecimalPlaces: 4)
            }
        )
    }
    @State private var closePrice: String = ""
    @State private var fee: String = ""
    @State private var closeDate: Date = Date()
    @State private var showDatePicker = false

    // MARK: - Validation

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var isSaving = false

    // MARK: - Options Direction

    /// True when closing a short option position (Buy to Close).
    private var isBTC: Bool { holding.isOption && holding.isShortPosition }
    /// True when closing a long option position (Sell to Close).
    private var isSTC: Bool { holding.isOption && !holding.isShortPosition }

    private var closeActionTitle: String {
        if isBTC { return "Buy to Close (BTC)" }
        if isSTC { return "Sell to Close (STC)" }
        return holding.assetType == .cash ? "Withdrawal Details" : "Sale Details"
    }

    private var confirmButtonLabel: String {
        if isBTC { return "Confirm BTC" }
        if isSTC { return "Confirm STC" }
        return holding.assetType == .cash ? "Confirm Withdrawal" : "Confirm Sale"
    }

    private var lotCardTitle: String {
        if isBTC { return "STO LOT — BUYING TO CLOSE" }
        if isSTC { return "BTO LOT — SELLING TO CLOSE" }
        return "LOT BEING SOLD"
    }

    /// ×100 for options lots (1 contract = 100 shares).
    private var contractMultiplier: Decimal { holding.isOption ? 100 : 1 }

    // MARK: - Computed

    private var maxQty: Decimal { lot.remainingQty }
    private var closeQty: Decimal? { Decimal.from(quantity) }
    private var price: Decimal? { Decimal.from(closePrice) }

    /// For STC/stock: proceeds received. For BTC: cost to close (what you pay).
    private var closingAmount: Decimal? {
        guard let qty = closeQty, let p = price, qty > 0, p > 0 else { return nil }
        let feeDecimal = Decimal.from(fee) ?? 0
        let m = contractMultiplier
        if isBTC {
            return (qty * p * m + feeDecimal).rounded(to: 2)
        } else {
            return (qty * p * m - feeDecimal).rounded(to: 2)
        }
    }

    private var realizedPnL: Decimal? {
        guard let qty = closeQty, let amt = closingAmount else { return nil }
        let m = contractMultiplier
        let costBasis = (qty * lot.splitAdjustedCostBasisPerShare * m).rounded(to: 2)
        if isBTC {
            // P&L = premium received − cost to close
            return (costBasis - amt).rounded(to: 2)
        } else {
            // P&L = proceeds − cost basis
            return (amt - costBasis).rounded(to: 2)
        }
    }

    private var isFullClose: Bool { closeQty == maxQty }

    private var taxEstimate: TaxEstimate? {
        guard let pnl = realizedPnL, pnl > 0 else { return nil }
        let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
        return engine.estimate(
            gain: pnl,
            purchaseDate: lot.purchaseDate,
            saleDate: closeDate,
            isSection1256: holding.isSection1256
        )
    }

    private var canSave: Bool {
        guard let qty = closeQty, let p = price else { return false }
        return qty > 0 && qty <= maxQty && p >= 0
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
                        lotSummaryCard
                        closeCard
                        if let est = taxEstimate {
                            taxBreakdownCard(est)
                        }
                        saveButton
                    }
                    .padding(16)
                }
            }
            .navigationTitle(holding.isOption
                             ? "\(isBTC ? "BTC" : "STC") — Lot #\(lot.lotNumber)"
                             : (holding.assetType == .cash ? "Withdraw — Lot #\(lot.lotNumber)" : "Sell Lot #\(lot.lotNumber)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
            }
            .alert("Check Your Inputs", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .onAppear {
                quantity = maxQty.asQuantity(maxDecimalPlaces: 4)
                sliderFraction = 1.0
            }
        }
    }

    // MARK: - Lot Summary Card

    private var lotSummaryCard: some View {
        FormCard(title: lotCardTitle) {
            VStack(spacing: 10) {
                HStack {
                    Text(holding.symbol)
                        .font(AppFont.mono(15, weight: .bold))
                        .foregroundColor(.textPrimary)
                    AssetTypeChip(type: holding.assetType)
                    if holding.isOption {
                        SmallChip(label: isBTC ? "STO" : "BTO", color: isBTC ? .appPurple : .appBlue)
                    }
                    Spacer()
                    Text("Lot #\(lot.lotNumber)")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textMuted)
                }

                Divider().background(Color.appBorder)

                HStack {
                    labelValue(
                        label: "Opened",
                        value: lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year())
                    )
                    Spacer()
                    labelValue(
                        label: "Available",
                        value: "\(maxQty.asQuantity(maxDecimalPlaces: 4)) \(holding.isOption ? "contracts" : "shares")"
                    )
                    Spacer()
                    labelValue(
                        label: holding.isOption ? (isBTC ? "STO Premium" : "BTO Premium") : "Cost Basis",
                        value: lot.splitAdjustedCostBasisPerShare.asCurrency + "/sh"
                    )
                }

                if !holding.isOption {
                    if lot.isLongTerm {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.appGreen)
                            Text("Long-term — qualifies for reduced tax rate")
                                .font(.system(size: 11))
                                .foregroundColor(.appGreen)
                        }
                    } else if let days = lot.daysToLongTerm {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                                .foregroundColor(.appGold)
                            Text("Short-term — \(days) day\(days == 1 ? "" : "s") until long-term")
                                .font(.system(size: 11))
                                .foregroundColor(.appGold)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Close Card

    private var closeCard: some View {
        FormCard(title: holding.isOption ? closeActionTitle.uppercased() : "SALE DETAILS") {
            VStack(spacing: 12) {
                datePickerRow(label: "Close Date", date: $closeDate, isExpanded: $showDatePicker)

                Divider().background(Color.appBorder)

                // Quantity slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(holding.isOption ? "CONTRACTS" : "QUANTITY")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textMuted)
                        Spacer()
                        if let qty = closeQty, qty > 0 {
                            Text(qty == maxQty
                                 ? (holding.isOption ? "Full close" : "Full sell")
                                 : (holding.isOption ? "Partial close" : "Partial sell"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(qty == maxQty ? .appGreen : .appBlue)
                        }
                    }
                    Slider(value: sliderBinding, in: 0...1)
                        .tint(.appBlue)
                    TextField(maxQty.asQuantity(maxDecimalPlaces: 4), text: $quantity)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .onChange(of: quantity) { _, v in
                            if let qty = Decimal.from(v), maxQty > 0 {
                                sliderFraction = min(max(NSDecimalNumber(decimal: qty / maxQty).doubleValue, 0), 1)
                            }
                        }
                }

                Divider().background(Color.appBorder)

                FormField(label: holding.isOption ? "Close Price / Share" : "Sell Price / Share",
                          placeholder: "0.00") {
                    TextField("0.00", text: $closePrice)
                        .keyboardType(.decimalPad)
                }

                Divider().background(Color.appBorder)

                FormField(label: "Fee / Commission (optional)", placeholder: "0.00") {
                    TextField("0.00", text: $fee)
                        .keyboardType(.decimalPad)
                }

                if let amt = closingAmount {
                    Divider().background(Color.appBorder)
                    HStack {
                        Text(isBTC ? "Cost to Close" : "Proceeds")
                            .font(.system(size: 12))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text(amt.asCurrency)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPrimary)
                    }
                    if let pnl = realizedPnL {
                        HStack {
                            Text("Realized P&L")
                                .font(.system(size: 12))
                                .foregroundColor(.textSub)
                            Spacer()
                            Text(pnl.asCurrencySigned)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color.pnlColor(pnl))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tax Breakdown Card

    @ViewBuilder
    private func taxBreakdownCard(_ est: TaxEstimate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tier 3 disclaimer at top (gold banner)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.appGold)
                Text(TaxDisclaimer.tier3)
                    .font(AppFont.body(11))
                    .foregroundColor(.textSub)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appGold.opacity(0.07))

            Divider().background(Color.appBorder)

            // Header
            HStack {
                Text("TAX ESTIMATE \(est.isLongTerm ? "(LT)" : "(ST)")\(est.isSection1256 ? " · 60/40" : "")")
                    .font(AppFont.mono(10, weight: .bold))
                    .foregroundColor(.textMuted)
                Spacer()
                Text("~ Estimated only")
                    .font(AppFont.mono(9))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Tax rows
            Group {
                taxRow(label: "Federal \(est.isLongTerm ? "LT" : "ST") ~",
                       rate: est.federalRate,
                       amount: est.federalTax)
                taxRow(label: "NIIT ~",
                       rate: est.niit > 0 ? Decimal(string: "3.8") : nil,
                       amount: est.niit,
                       dimWhenZero: true)
                if let stateCode = taxProfileManager.profile.state {
                    taxRow(label: "\(stateCode) State ~",
                           rate: est.stateRate,
                           amount: est.stateTax)
                }
                if let cityKey = taxProfileManager.profile.city,
                   let cityName = TaxRatesLoader.load().cities[cityKey]?.name {
                    taxRow(label: "\(cityName) City ~",
                           rate: est.cityRate,
                           amount: est.cityTax)
                }
            }
            .padding(.horizontal, 16)

            Divider().background(Color.appBorder).padding(.horizontal, 16).padding(.vertical, 8)

            // Total tax
            HStack {
                Text("Total Est. Tax ~")
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(est.totalTax.asCurrency)
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.appRed)
            }
            .padding(.horizontal, 16)

            // Net proceeds
            HStack {
                Text("Est. Net Proceeds ~")
                    .font(AppFont.mono(12, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(est.netProceeds.asCurrency)
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.appGreen)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            // Warnings
            if est.amtWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appGold)
                    Text("Large gain may trigger AMT — consult a tax professional.")
                        .font(AppFont.body(11))
                        .foregroundColor(.appGold)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            if est.washSaleWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appGold)
                    Text("Wash sale risk — same security purchased within 30 days. Loss may be disallowed.")
                        .font(AppFont.body(11))
                        .foregroundColor(.appGold)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            // Tier 1 footer
            Text("~ \(taxProfileManager.profile.shortLabel) · Verify cost basis with broker · Not tax advice")
                .font(AppFont.body(10))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func taxRow(label: String, rate: Decimal?, amount: Decimal, dimWhenZero: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(AppFont.mono(11))
                .foregroundColor(dimWhenZero && amount == 0 ? .textMuted : .textSub)
            if let r = rate, r > 0 {
                Text("(\(r.asPercent()))")
                    .font(AppFont.mono(10))
                    .foregroundColor(.textMuted)
            }
            Spacer()
            Text(amount == 0 ? "—" : amount.asCurrency)
                .font(AppFont.mono(11, weight: .medium))
                .foregroundColor(dimWhenZero && amount == 0 ? .textMuted : .textPrimary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Group {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Text(confirmButtonLabel)
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
        guard let qty = closeQty, qty > 0, qty <= maxQty,
              let p = price, p >= 0 else {
            validationMessage = "Invalid quantity or price."
            showValidationError = true
            return
        }

        isSaving = true
        let feeDecimal = Decimal.from(fee) ?? 0
        let m = contractMultiplier

        // BTC: totalAmount = cost paid (qty × price × 100 + fee) — used by realizedPnLStats as: costBasis - totalAmount
        // STC/sell: totalAmount = proceeds received (qty × price × [100|1] - fee) — used as: totalAmount - costBasis
        let txTotalAmount: Decimal = isBTC
            ? (qty * p * m + feeDecimal).rounded(to: 2)
            : (qty * p * m - feeDecimal).rounded(to: 2)

        let snapRemainingQty = lot.remainingQty
        let snapIsClosed     = lot.isClosed

        // Update lot remaining quantity
        lot.remainingQty = (lot.remainingQty - qty).rounded(to: 8)
        if lot.remainingQty <= 0 {
            lot.remainingQty = 0
            lot.isClosed = true
        }

        let tx = Transaction.createSell(
            in: context,
            holdingId: holding.id,
            lotId: lot.id,
            quantity: qty,
            pricePerShare: p,
            fee: feeDecimal,
            tradeDate: closeDate,
            totalAmountOverride: txTotalAmount,
            taxEstimate: taxEstimate
        )

        do {
            try context.save()
            // Auto-credit net proceeds to Cash (skip BTC and Cash withdrawals)
            if !isBTC && holding.assetType != .cash {
                let label = isSTC ? "\(holding.symbol) STC" : "\(holding.symbol) Sell"
                CashLedgerService.credit(amount: txTotalAmount, date: closeDate, sourceNote: label, in: context)
                try? context.save()
            }
            onCompleted?(tx, (id: lot.id, remainingQty: snapRemainingQty, isClosed: snapIsClosed))
            dismiss()
        } catch {
            validationMessage = "Failed to save: \(error.localizedDescription)"
            showValidationError = true
            context.rollback()
        }

        isSaving = false
    }

    // MARK: - Helpers

    private func labelValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(AppFont.statLabel)
                .foregroundColor(.textMuted)
                .textCase(.uppercase)
            Text(value)
                .font(AppFont.mono(11, weight: .bold))
                .foregroundColor(.textPrimary)
        }
    }

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
