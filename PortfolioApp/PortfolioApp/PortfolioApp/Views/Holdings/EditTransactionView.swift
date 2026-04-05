import SwiftUI
import CoreData

/// Edit a sell (or buy) transaction — primarily lets the user correct the trade date,
/// price, total amount, and fee. On save it recalculates isLongTerm and stored tax
/// estimates using the updated date vs the linked lot's purchase date.
struct EditTransactionView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var taxProfileManager: TaxProfileManager

    let transaction: Transaction

    @State private var tradeDate: Date
    @State private var pricePerShare: String
    @State private var totalAmount: String
    @State private var fee: String

    @State private var datePickerExpanded = false
    @State private var validationError: String?

    init(transaction: Transaction) {
        self.transaction = transaction
        _tradeDate      = State(initialValue: transaction.tradeDate)
        _pricePerShare  = State(initialValue: transaction.pricePerShare == 0 ? "" : (transaction.pricePerShare as NSDecimalNumber).stringValue)
        _totalAmount    = State(initialValue: transaction.totalAmount == 0 ? "" : (transaction.totalAmount as NSDecimalNumber).stringValue)
        _fee            = State(initialValue: transaction.fee == 0 ? "" : (transaction.fee as NSDecimalNumber).stringValue)
    }

    // MARK: - Lot for LT/ST Recalculation

    private var linkedLot: Lot? {
        guard let lotId = transaction.lotId else { return nil }
        let req = Lot.fetchRequest() as NSFetchRequest<Lot>
        req.predicate = NSPredicate(format: "id == %@", lotId as CVarArg)
        req.fetchLimit = 1
        return try? context.fetch(req).first
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        typeHeader
                        formCard
                        if transaction.type == .sell, let lot = linkedLot {
                            ltStPreviewCard(lot: lot)
                        }
                        if let err = validationError {
                            Text(err)
                                .font(AppFont.body(13))
                                .foregroundColor(.appRed)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appBlue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.appBlue)
                }
            }
        }
    }

    // MARK: - Type Header

    private var typeHeader: some View {
        HStack(spacing: 8) {
            Text(transaction.type.rawValue.uppercased())
                .font(AppFont.mono(11, weight: .bold))
                .foregroundColor(transaction.type == .sell ? .appRed : .appBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((transaction.type == .sell ? Color.appRed : Color.appBlue).opacity(0.12))
                .clipShape(Capsule())
            Text(transaction.quantity.asQuantity(maxDecimalPlaces: 4) + " shares")
                .font(AppFont.mono(13))
                .foregroundColor(.textSub)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Form Card

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSACTION DETAILS")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 14)

            VStack(spacing: 0) {
                // Trade Date
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trade Date")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.textMuted)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            datePickerExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(tradeDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.textPrimary)
                            Spacer()
                            Image(systemName: datePickerExpanded ? "chevron.up" : "calendar")
                                .font(.system(size: 12))
                                .foregroundColor(.appBlue)
                        }
                    }
                    if datePickerExpanded {
                        DatePicker("", selection: $tradeDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(.appBlue)
                            .onChange(of: tradeDate) { _, _ in
                                withAnimation { datePickerExpanded = false }
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                // Price per share
                fieldRow(label: "Price / Share", placeholder: "0.00", text: $pricePerShare)

                Divider().background(Color.appBorder)

                // Total amount
                fieldRow(label: transaction.type == .sell ? "Total Proceeds" : "Total Cost",
                         placeholder: "0.00",
                         text: $totalAmount)

                Divider().background(Color.appBorder)

                // Fee
                fieldRow(label: "Fee / Commission", placeholder: "0.00", text: $fee)
            }
        }
        .cardStyle()
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.textSub)
            Spacer()
            TextField(placeholder, text: text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .frame(width: 120)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - LT/ST Preview Card

    private func ltStPreviewCard(lot: Lot) -> some View {
        let ltThreshold = Calendar.current.date(byAdding: .day, value: 366, to: lot.purchaseDate)!
        let willBeLT = tradeDate > ltThreshold
        let currentlyLT = transaction.isLongTerm
        let dateChanged = tradeDate != transaction.tradeDate

        return VStack(alignment: .leading, spacing: 10) {
            Text("HOLDING PERIOD IMPACT")
                .sectionTitleStyle()
                .padding(.horizontal, 20)
                .padding(.top, 20)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PURCHASE DATE")
                        .font(AppFont.statLabel)
                        .foregroundColor(.textMuted)
                    Text(lot.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("LT THRESHOLD")
                        .font(AppFont.statLabel)
                        .foregroundColor(.textMuted)
                    Text(ltThreshold.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.appGold)
                }
            }
            .padding(.horizontal, 20)

            Divider().background(Color.appBorder).padding(.horizontal, 20)

            HStack {
                Text("Classification")
                    .font(AppFont.body(13))
                    .foregroundColor(.textSub)
                Spacer()
                HStack(spacing: 6) {
                    if dateChanged && willBeLT != currentlyLT {
                        Text(currentlyLT ? "LT" : "ST")
                            .font(AppFont.mono(11, weight: .bold))
                            .foregroundColor(currentlyLT ? .appGreen : .appGold)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.textMuted)
                    }
                    Text(willBeLT ? "LONG-TERM" : "SHORT-TERM")
                        .font(AppFont.mono(11, weight: .bold))
                        .foregroundColor(willBeLT ? .appGreen : .appGold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((willBeLT ? Color.appGreen : Color.appGold).opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .cardStyle()
    }

    // MARK: - Save

    private func save() {
        guard let price = Decimal(string: pricePerShare.isEmpty ? "0" : pricePerShare),
              let total = Decimal(string: totalAmount.isEmpty ? "0" : totalAmount) else {
            validationError = "Invalid number format."
            return
        }
        let feeVal = Decimal(string: fee.isEmpty ? "0" : fee) ?? 0

        transaction.tradeDate     = tradeDate
        transaction.pricePerShare = price
        transaction.totalAmount   = total
        transaction.fee           = feeVal
        transaction.settlementDate = tradeDate.settlementDateT1

        // Recalculate isLongTerm if this is a sell with a linked lot
        if transaction.type == .sell, let lot = linkedLot {
            let ltThreshold = Calendar.current.date(byAdding: .day, value: 366, to: lot.purchaseDate)!
            let nowLT = tradeDate > ltThreshold
            transaction.isLongTerm = nowLT

            // Re-run tax estimate if profile is complete
            if taxProfileManager.isProfileComplete {
                let engine = TaxEngine(rates: TaxRatesLoader.load(), profile: taxProfileManager.profile)
                let costBasis = (transaction.quantity * lot.splitAdjustedCostBasisPerShare).rounded(to: 2)
                let gain = total - costBasis
                let est = engine.estimate(gain: gain, purchaseDate: lot.purchaseDate, saleDate: tradeDate)
                transaction.realizedGain = est.gain
                transaction.isLongTerm   = est.isLongTerm
                transaction.federalTax   = est.federalTax
                transaction.niit         = est.niit
                transaction.stateTax     = est.stateTax
                transaction.cityTax      = est.cityTax
                transaction.totalTax     = est.totalTax
            }
        }

        try? context.save()
        dismiss()
    }
}
