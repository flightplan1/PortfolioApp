import SwiftUI
import CoreData

struct AddLotView: View {

    let holding: Holding
    let lot: Lot?   // nil = add mode, non-nil = edit mode

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest private var existingLots: FetchedResults<Lot>

    // MARK: - Form State

    @State private var quantity: String = ""
    @State private var pricePerShare: String = ""
    @State private var fee: String = ""
    @State private var tradeDate: Date = Date()
    @State private var showDatePicker = false

    // MARK: - Validation

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    // Cash deduction
    @State private var availableCash: Decimal = 0
    @State private var deductFromCash: Bool = false

    private var purchaseCost: Decimal? {
        guard let qty = Decimal.from(quantity), qty > 0,
              let price = Decimal.from(pricePerShare), price >= 0 else { return nil }
        let feeDecimal = Decimal.from(fee) ?? 0
        return (qty * price * holding.lotMultiplier + feeDecimal).rounded(to: 2)
    }

    private var isEditMode: Bool { lot != nil }
    private var canEditQty: Bool {
        guard let lot else { return true }
        return lot.remainingQty == lot.originalQty
    }

    init(holding: Holding, lot: Lot?) {
        self.holding = holding
        self.lot = lot
        _existingLots = FetchRequest(fetchRequest: Lot.openLots(for: holding.id), animation: .none)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        transactionCard
                        if isEditMode && !canEditQty {
                            partialSaleWarning
                        }
                        if !isEditMode && availableCash > 0 {
                            cashDeductionCard
                        }
                        saveButton
                        if isEditMode {
                            deleteLotButton
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(isEditMode ? "Edit Lot #\(lot?.lotNumber ?? 0)" : "Add Lot")
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
            .alert("Delete Lot #\(lot?.lotNumber ?? 0)?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteLot() }
            } message: {
                Text("This will permanently remove the lot and cannot be undone.")
            }
            .onAppear {
                prefillIfEditing()
                if !isEditMode {
                    availableCash = CashLedgerService.availableBalance(in: context)
                    deductFromCash = availableCash > 0
                }
            }
        }
    }

    // MARK: - Cash Deduction Card

    private var cashDeductionCard: some View {
        FormCard(title: "CASH BALANCE") {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deduct from Cash")
                            .font(AppFont.body(14))
                            .foregroundColor(.textPrimary)
                        if let cost = purchaseCost {
                            Text("Purchase cost: \(cost.asCurrency)")
                                .font(AppFont.mono(11))
                                .foregroundColor(.textMuted)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $deductFromCash)
                        .tint(.appGreen)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                HStack {
                    Text("Available Cash")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text(availableCash.asCurrency)
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(availableCash > 0 ? .appGreen : .textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Transaction Card

    private var transactionCard: some View {
        FormCard(title: isEditMode ? "LOT DETAILS" : "NEW LOT") {
            VStack(spacing: 12) {
                // Holding context
                HStack(spacing: 8) {
                    Text(holding.symbol)
                        .font(AppFont.mono(15, weight: .bold))
                        .foregroundColor(.textPrimary)
                    AssetTypeChip(type: holding.assetType)
                    Spacer()
                    if isEditMode {
                        Text("Lot #\(lot?.lotNumber ?? 0)")
                            .font(AppFont.mono(11))
                            .foregroundColor(.textMuted)
                    } else {
                        Text("Lot #\(nextLotNumber)")
                            .font(AppFont.mono(11))
                            .foregroundColor(.textMuted)
                    }
                }

                Divider().background(Color.appBorder)

                // Trade Date
                datePickerRow(label: "Trade Date", date: $tradeDate, isExpanded: $showDatePicker)

                Divider().background(Color.appBorder)

                // Quantity + Price
                HStack(spacing: 12) {
                    FormField(label: holding.isOption ? "Contracts" : "Quantity", placeholder: "100") {
                        TextField("100", text: $quantity)
                            .keyboardType(.decimalPad)
                            .disabled(isEditMode && !canEditQty)
                            .foregroundColor(isEditMode && !canEditQty ? .textMuted : .textPrimary)
                    }
                    FormField(label: holding.isOption ? "Premium / Share" : "Price / Share", placeholder: "875.00") {
                        TextField("875.00", text: $pricePerShare)
                            .keyboardType(.decimalPad)
                    }
                }

                // Fee — options only
                if holding.isOption {
                    Divider().background(Color.appBorder)
                    FormField(label: "Fee / Commission", placeholder: "0.00") {
                        TextField("0.00", text: $fee)
                            .keyboardType(.decimalPad)
                    }
                }

                // Cost basis preview
                if let costBasis = totalCostBasis {
                    Divider().background(Color.appBorder)
                    HStack {
                        Text("Total cost basis")
                            .font(.system(size: 12))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text(costBasis.rounded(to: 2).asCurrency)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Partial Sale Warning

    private var partialSaleWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundColor(.appGold)
            Text("Quantity is locked — this lot has been partially sold.")
                .font(.system(size: 12))
                .foregroundColor(.appGold)
        }
        .padding(12)
        .background(Color.appGold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.appGold.opacity(0.25), lineWidth: 1)
        )
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
                    Text(isEditMode ? "Save Changes" : "Add Lot")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canSave ? Color.appBlue : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!canSave || isSaving)
    }

    // MARK: - Delete Button

    private var deleteLotButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("Delete Lot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.appRed)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.appRedDim)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.appRedBorder, lineWidth: 1)
                )
        }
    }

    private func deleteLot() {
        guard let lot else { return }
        lot.softDelete()
        try? context.save()
        dismiss()
    }

    // MARK: - Helpers

    private var nextLotNumber: Int32 {
        (existingLots.map { $0.lotNumber }.max() ?? 0) + 1
    }

    private var totalCostBasis: Decimal? {
        guard let qty = Decimal.from(quantity), let price = Decimal.from(pricePerShare),
              qty > 0, price > 0 else { return nil }
        let feeDecimal = Decimal.from(fee) ?? 0
        if holding.isOption, let contracts = Int(quantity) {
            return OptionsCalculator.totalCost(contracts: contracts, premiumPerShare: price, fee: feeDecimal)
        }
        return qty * price + feeDecimal
    }

    private var canSave: Bool {
        Decimal.from(quantity) != nil && Decimal.from(pricePerShare) != nil
    }

    private func prefillIfEditing() {
        guard let lot else { return }
        quantity = lot.originalQty.asQuantity(maxDecimalPlaces: 4)
        pricePerShare = lot.originalCostBasisPerShare.formatted()
        tradeDate = lot.purchaseDate
    }

    // MARK: - Save / Edit

    private func save() {
        guard let qty = Decimal.from(quantity), qty > 0,
              let price = Decimal.from(pricePerShare), price >= 0 else {
            validationMessage = "Please enter a valid quantity and price."
            showValidationError = true
            return
        }

        isSaving = true
        let feeDecimal = Decimal.from(fee) ?? 0

        if let existingLot = lot {
            // Edit mode — update cost basis and date only
            let feePerShare = qty > 0 ? feeDecimal / qty : 0
            let adjustedBasis = price + feePerShare
            existingLot.originalCostBasisPerShare = adjustedBasis
            existingLot.splitAdjustedCostBasisPerShare = adjustedBasis
            existingLot.totalCostBasis = (qty * price + feeDecimal).rounded(to: 2)
            existingLot.purchaseDate = tradeDate
            if canEditQty {
                existingLot.originalQty = qty
                existingLot.splitAdjustedQty = qty
                existingLot.remainingQty = qty
            }
        } else {
            // Add mode — create new lot + transaction
            let lotQty: Decimal
            if holding.isOption, let contracts = Int(quantity) {
                lotQty = Decimal(contracts)
            } else {
                lotQty = qty
            }

            let newLot = Lot.create(
                in: context,
                holdingId: holding.id,
                lotNumber: nextLotNumber,
                quantity: lotQty,
                costBasisPerShare: price,
                purchaseDate: tradeDate,
                fee: feeDecimal,
                source: .manual
            )

            _ = Transaction.createBuy(
                in: context,
                holdingId: holding.id,
                lotId: newLot.id,
                quantity: lotQty,
                pricePerShare: price,
                fee: feeDecimal,
                tradeDate: tradeDate
            )
        }

        do {
            try context.save()
            // Deduct purchase cost from Cash if toggled on (add mode only)
            if !isEditMode && deductFromCash, let cost = purchaseCost {
                CashLedgerService.debit(amount: cost, in: context)
                try? context.save()
            }
            dismiss()
        } catch {
            validationMessage = "Failed to save: \(error.localizedDescription)"
            showValidationError = true
            context.rollback()
        }

        isSaving = false
    }

    // MARK: - Date Picker

    @ViewBuilder
    private func datePickerRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.wrappedValue = false
                        }
                    }
            }
        }
    }
}
