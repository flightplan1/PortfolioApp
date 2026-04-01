import SwiftUI
import CoreData

// MARK: - AddDividendView
// Manual dividend entry sheet.
// Supports both cash dividends and DRIP reinvestment.
// On DRIP: presents a confirmation step before creating the lot.

struct AddDividendView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form State

    @State private var payDate:          Date = Date()
    @State private var exDividendDate:   Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var hasExDivDate      = false
    @State private var dividendPerShare: String = ""
    @State private var sharesHeld:       String = ""
    @State private var isReinvested:     Bool = false
    @State private var reinvestPrice:    String = ""

    // Date picker expansion
    @State private var showPayDatePicker   = false
    @State private var showExDivPicker     = false

    // DRIP confirmation step
    @State private var showDRIPConfirm     = false

    // Save state
    @State private var isSaving            = false
    @State private var showError           = false
    @State private var errorMessage        = ""

    // MARK: - Computed

    private var dps: Decimal? { Decimal.from(dividendPerShare) }
    private var shares: Decimal? { Decimal.from(sharesHeld) }
    private var reinvestPriceDecimal: Decimal? { Decimal.from(reinvestPrice) }

    private var grossAmount: Decimal? {
        guard let d = dps, let s = shares, d > 0, s > 0 else { return nil }
        return (d * s).rounded(to: 2)
    }

    private var reinvestedShares: Decimal? {
        guard isReinvested,
              let gross = grossAmount,
              let price = reinvestPriceDecimal, price > 0 else { return nil }
        return (gross / price).rounded(to: 6)
    }

    private var canSave: Bool {
        guard dps != nil, shares != nil, grossAmount != nil else { return false }
        if isReinvested { return reinvestPriceDecimal != nil }
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        dividendCard
                        if isReinvested {
                            dripCard
                        }
                        if let gross = grossAmount {
                            summaryCard(gross: gross)
                        }
                        saveButton
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Dividend")
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
            .confirmationDialog(
                "Reinvest \(reinvestedShares.map { "\($0.formatted()) shares" } ?? "dividend") in \(holding.symbol)?",
                isPresented: $showDRIPConfirm,
                titleVisibility: .visible
            ) {
                Button("Create DRIP Lot") { saveDRIP() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let gross = grossAmount, let price = reinvestPriceDecimal, price > 0,
                   let newShares = reinvestedShares {
                    Text("A new lot of \(newShares.formatted()) shares will be created at \(price.asCurrency)/share (cost basis \(gross.asCurrency)).")
                }
            }
        }
    }

    // MARK: - Dividend Card

    private var dividendCard: some View {
        FormCard(title: "DIVIDEND DETAILS") {
            VStack(spacing: 0) {
                // Holding context
                HStack(spacing: 8) {
                    Text(holding.symbol)
                        .font(AppFont.mono(15, weight: .bold))
                        .foregroundColor(.textPrimary)
                    AssetTypeChip(type: holding.assetType)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                // Pay Date
                datePickerRow(label: "Pay Date", date: $payDate, isExpanded: $showPayDatePicker)

                Divider().background(Color.appBorder)

                // Ex-Dividend Date toggle
                VStack(spacing: 0) {
                    HStack {
                        Text("Ex-Dividend Date")
                            .font(AppFont.body(14))
                            .foregroundColor(.textPrimary)
                        Spacer()
                        Toggle("", isOn: $hasExDivDate)
                            .tint(.appBlue)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if hasExDivDate {
                        Divider().background(Color.appBorder)
                        datePickerRow(label: "Ex-Div Date", date: $exDividendDate, isExpanded: $showExDivPicker)
                    }
                }

                Divider().background(Color.appBorder)

                // Dividend Per Share + Shares Held
                HStack(spacing: 12) {
                    FormField(label: "Dividend / Share", placeholder: "0.50") {
                        TextField("0.50", text: $dividendPerShare)
                            .keyboardType(.decimalPad)
                    }
                    FormField(label: "Shares Held", placeholder: "100") {
                        TextField("100", text: $sharesHeld)
                            .keyboardType(.decimalPad)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)

                // DRIP Toggle
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reinvest (DRIP)")
                            .font(AppFont.body(14))
                            .foregroundColor(.textPrimary)
                        Text("Creates a new lot at the reinvestment price")
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                    }
                    Spacer()
                    Toggle("", isOn: $isReinvested)
                        .tint(.appGold)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - DRIP Card

    private var dripCard: some View {
        FormCard(title: "DRIP REINVESTMENT") {
            VStack(spacing: 0) {
                FormField(label: "Reinvestment Price / Share", placeholder: "185.00") {
                    TextField("185.00", text: $reinvestPrice)
                        .keyboardType(.decimalPad)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let newShares = reinvestedShares {
                    Divider().background(Color.appBorder)
                    HStack {
                        Text("Estimated new shares")
                            .font(AppFont.body(13))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text(newShares.formatted())
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(.appGold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Summary Card

    private func summaryCard(gross: Decimal) -> some View {
        FormCard(title: "SUMMARY") {
            VStack(spacing: 0) {
                summaryRow(label: "Gross Dividend", value: gross.asCurrency, valueColor: .appGreen)
                if isReinvested, let newShares = reinvestedShares, let price = reinvestPriceDecimal {
                    Divider().background(Color.appBorder)
                    summaryRow(label: "Shares Reinvested", value: newShares.formatted(), valueColor: .appGold)
                    Divider().background(Color.appBorder)
                    summaryRow(label: "@ Price", value: price.asCurrency, valueColor: .textSub)
                }
            }
        }
    }

    private func summaryRow(label: String, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            if isReinvested {
                showDRIPConfirm = true
            } else {
                saveCash()
            }
        } label: {
            HStack {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(isReinvested ? "Record DRIP Dividend" : "Record Dividend")
                        .font(AppFont.body(16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(canSave ? Color.appBlue : Color.appBorder)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!canSave || isSaving)
    }

    // MARK: - Actions

    private func saveCash() {
        guard let d = dps, let s = shares else { return }
        isSaving = true
        do {
            let event = try DividendService.shared.recordCashDividend(
                holding: holding,
                payDate: payDate,
                exDividendDate: hasExDivDate ? exDividendDate : nil,
                dividendPerShare: d,
                sharesHeld: s,
                in: context
            )
            // Schedule pay-date notification
            DividendNotificationManager.shared.scheduleDividendReceivedAlert(for: event)
            if hasExDivDate {
                DividendNotificationManager.shared.scheduleExDivAlert(for: holding)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func saveDRIP() {
        guard let d = dps, let s = shares, let price = reinvestPriceDecimal else { return }
        isSaving = true
        do {
            let (event, _) = try DividendService.shared.recordDRIP(
                holding: holding,
                payDate: payDate,
                exDividendDate: hasExDivDate ? exDividendDate : nil,
                dividendPerShare: d,
                sharesHeld: s,
                reinvestedPricePerShare: price,
                in: context
            )
            DividendNotificationManager.shared.scheduleDividendReceivedAlert(for: event)
            if hasExDivDate {
                DividendNotificationManager.shared.scheduleExDivAlert(for: holding)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    // MARK: - Date Picker Row

    private func datePickerRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Text(label)
                        .font(AppFont.body(14))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Text(date.wrappedValue, style: .date)
                        .font(AppFont.mono(13))
                        .foregroundColor(.textSub)
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .tint(.appBlue)
            }
        }
    }
}
