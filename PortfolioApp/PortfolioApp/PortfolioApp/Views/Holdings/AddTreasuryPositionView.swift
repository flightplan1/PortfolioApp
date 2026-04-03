import SwiftUI
import CoreData

// MARK: - AddTreasuryPositionView
// Presented as a sheet to add rich TreasuryPosition details to an existing treasury Holding.
// Also used from AddHoldingView when asset type == .treasury.

struct AddTreasuryPositionView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    // Position type
    @State private var instrument: TreasuryInstrument = .tBill

    // Core fields
    @State private var faceValue     = ""
    @State private var purchasePrice = ""
    @State private var purchaseDate  = Date()
    @State private var maturityDate  = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var cusip         = ""

    // Coupon fields (T-Note, T-Bond, TIPS)
    @State private var couponRate    = ""    // % annual, e.g. "4.5"

    // TIPS
    @State private var inflationAdjPrincipal = ""

    // I-Bond
    @State private var ibondFixedRate      = ""   // % e.g. "1.3"
    @State private var ibondInflationRate  = ""   // semiannual CPI % e.g. "2.24"

    // UI state
    @State private var showPurchaseDatePicker = false
    @State private var showMaturityDatePicker = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false

    // MARK: - Computed

    private var needsCoupon: Bool {
        instrument == .tNote || instrument == .tBond || instrument == .tips
    }

    private var ytmPreview: Decimal? {
        guard let fv = Decimal(string: faceValue), fv > 0,
              let pp = Decimal(string: purchasePrice), pp > 0 else { return nil }
        let cr = Decimal(string: couponRate.isEmpty ? "0" : couponRate) ?? 0
        return TreasuryEngine.ytmAtPurchase(
            instrument: instrument,
            faceValue: fv,
            purchasePrice: pp,
            couponRate: cr / 100,
            purchaseDate: purchaseDate,
            maturityDate: maturityDate
        )
    }

    private var canSave: Bool {
        guard let fv = Decimal(string: faceValue), fv > 0,
              let pp = Decimal(string: purchasePrice), pp > 0 else { return false }
        if needsCoupon {
            guard let cr = Decimal(string: couponRate), cr >= 0 else { return false }
        }
        if instrument == .iBond {
            guard Decimal(string: ibondFixedRate) != nil,
                  Decimal(string: ibondInflationRate) != nil else { return false }
        }
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        instrumentCard
                        principalCard
                        if needsCoupon { couponCard }
                        if instrument == .tips { tipsCard }
                        if instrument == .iBond { iBondCard }
                        if let ytm = ytmPreview, instrument != .iBond {
                            ytmPreviewCard(ytm)
                        }
                        saveButton
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Treasury Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Instrument Card

    private var instrumentCard: some View {
        FormCard(title: "INSTRUMENT TYPE") {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TreasuryInstrument.allCases, id: \.self) { t in
                            FilterChip(label: t.shortLabel, isSelected: instrument == t) {
                                instrument = t
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Principal Card

    private var principalCard: some View {
        FormCard(title: "PRINCIPAL") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FormField(label: "Face Value ($)", placeholder: "1000.00") {
                        TextField("1000.00", text: $faceValue)
                            .keyboardType(.decimalPad)
                    }
                    FormField(label: "Purchase Price ($)", placeholder: "980.00") {
                        TextField("980.00", text: $purchasePrice)
                            .keyboardType(.decimalPad)
                    }
                }

                Divider().background(Color.appBorder).padding(.top, 12)

                datePickerRow(label: "Purchase Date", date: $purchaseDate, expanded: $showPurchaseDatePicker)

                Divider().background(Color.appBorder)

                datePickerRow(label: "Maturity Date", date: $maturityDate, expanded: $showMaturityDatePicker)

                Divider().background(Color.appBorder)

                FormField(label: "CUSIP (optional)", placeholder: "912796YG7") {
                    TextField("912796YG7", text: $cusip)
                        .onChange(of: cusip) { _, v in cusip = v.uppercased() }
                }
            }
        }
    }

    // MARK: - Coupon Card (T-Note, T-Bond, TIPS)

    private var couponCard: some View {
        FormCard(title: "COUPON") {
            VStack(spacing: 0) {
                FormField(label: "Annual Coupon Rate (%)", placeholder: "4.500") {
                    TextField("4.500", text: $couponRate)
                        .keyboardType(.decimalPad)
                }

                if let cr = Decimal(string: couponRate), cr > 0,
                   let fv = Decimal(string: faceValue), fv > 0 {
                    Divider().background(Color.appBorder)
                    let annual = (fv * cr / 100).rounded(to: 2)
                    let perPayment = (annual / 2).rounded(to: 2)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Annual: \(annual.asCurrency)")
                                .font(AppFont.mono(12))
                                .foregroundColor(.textSub)
                            Text("Per payment (semi-annual): \(perPayment.asCurrency)")
                                .font(AppFont.mono(12))
                                .foregroundColor(.textSub)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - TIPS Card

    private var tipsCard: some View {
        FormCard(title: "INFLATION ADJUSTMENT (OPTIONAL)") {
            FormField(label: "Current Inflation-Adj. Principal ($)", placeholder: "1020.00") {
                TextField("1020.00", text: $inflationAdjPrincipal)
                    .keyboardType(.decimalPad)
            }
        }
    }

    // MARK: - I-Bond Card

    private var iBondCard: some View {
        FormCard(title: "I-BOND RATES") {
            VStack(spacing: 0) {
                FormField(label: "Fixed Rate (%)", placeholder: "1.300") {
                    TextField("1.300", text: $ibondFixedRate)
                        .keyboardType(.decimalPad)
                }

                Divider().background(Color.appBorder)

                FormField(label: "Semiannual CPI Rate (%)", placeholder: "2.240") {
                    TextField("2.240", text: $ibondInflationRate)
                        .keyboardType(.decimalPad)
                }

                if let fixed = Decimal(string: ibondFixedRate),
                   let cpi   = Decimal(string: ibondInflationRate) {
                    Divider().background(Color.appBorder)
                    let composite = TreasuryEngine.iBondCompositeRate(fixedRate: fixed / 100, semiannualCPI: cpi / 100)
                    HStack {
                        Text("Composite Rate")
                            .font(AppFont.body(13))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text("\(String(format: "%.3f", ((composite * 100).rounded(to: 3) as NSDecimalNumber).doubleValue))%")
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(.appGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Divider().background(Color.appBorder)
                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                    Text("I-Bond rates update May & November. You can update the composite rate in the detail view.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - YTM Preview

    private func ytmPreviewCard(_ ytm: Decimal) -> some View {
        FormCard(title: "YIELD PREVIEW") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YTM at Purchase")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Text("\(String(format: "%.3f", ((ytm * 100).rounded(to: 3) as NSDecimalNumber).doubleValue))%")
                        .font(AppFont.mono(20, weight: .bold))
                        .foregroundColor(.appGreen)
                }
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 28))
                    .foregroundColor(.appGreen.opacity(0.4))
            }
            .padding(16)
        }
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
                    Text("Save Treasury Details")
                        .font(AppFont.body(16, weight: .semibold))
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

    // MARK: - Date Picker Helper

    @ViewBuilder
    private func datePickerRow(label: String, date: Binding<Date>, expanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(date.wrappedValue.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(.appBlue)
                }
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.appBlue)
                    .colorScheme(.dark)
                    .padding(.top, 4)
                    .onChange(of: date.wrappedValue) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue = false }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Save Action

    private func save() {
        guard let fv = Decimal(string: faceValue), fv > 0,
              let pp = Decimal(string: purchasePrice), pp > 0 else { return }

        isSaving = true

        let cr = needsCoupon ? (Decimal(string: couponRate) ?? 0) / 100 : Decimal(0)
        let fixedRate = instrument == .iBond ? (Decimal(string: ibondFixedRate) ?? 0) / 100 : Decimal(0)
        let inflRate  = instrument == .iBond ? (Decimal(string: ibondInflationRate) ?? 0) / 100 : Decimal(0)

        let pos = TreasuryPosition.create(
            in: context,
            holdingId: holding.id,
            instrument: instrument,
            faceValue: fv,
            purchasePrice: pp,
            purchaseDate: purchaseDate,
            maturityDate: maturityDate,
            couponRate: cr,
            cusip: cusip.isEmpty ? nil : cusip,
            ibondFixedRate: fixedRate,
            ibondInflationRate: inflRate
        )

        // Set TIPS inflation-adjusted principal if provided
        if instrument == .tips, let adjPrincipal = Decimal(string: inflationAdjPrincipal), adjPrincipal > 0 {
            pos.inflationAdjustedPrincipal = adjPrincipal
        }

        do {
            try context.save()
            // Generate coupon schedule for coupon-bearing instruments
            if pos.couponFrequency != .zero {
                CouponPayment.generateSchedule(for: pos, in: context)
                try context.save()
            }
            // Schedule maturity alert
            TreasuryMaturityService.shared.scheduleMaturityAlert(for: pos, symbol: holding.symbol)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isSaving = false
    }
}
