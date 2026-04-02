import SwiftUI
import CoreData

// MARK: - TreasuryDetailView
// Full-page detail view for a treasury holding.
// Routed from HoldingsListView / DashboardView instead of PositionDetailView.

struct TreasuryDetailView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest private var positions: FetchedResults<TreasuryPosition>
    @FetchRequest private var coupons: FetchedResults<CouponPayment>

    @State private var showAddTreasury = false
    @State private var showRecordMaturity = false
    @State private var showMarkCoupon: CouponPayment? = nil
    @State private var creditCashOnCoupon = true
    @State private var showDeleteHolding = false

    init(holding: Holding) {
        self.holding = holding
        _positions = FetchRequest(
            fetchRequest: TreasuryPosition.forHolding(holding.id),
            animation: .default
        )
        _coupons = FetchRequest(
            fetchRequest: CouponPayment.forHolding(holding.id),
            animation: .default
        )
    }

    private var position: TreasuryPosition? { positions.first }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    if let pos = position {
                        summaryCard(pos)
                        yieldCard(pos)
                        if pos.instrumentType == .tips { tipsCard(pos) }
                        if pos.instrumentType == .iBond { iBondCard(pos) }
                        if pos.couponFrequency != .zero { couponCard(pos) }
                        taxCard(pos)
                        maturityCard(pos)
                    } else {
                        noPositionCard
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(holding.symbol)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if position == nil {
                    Button {
                        showAddTreasury = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.appBlue)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddTreasury) {
            AddTreasuryPositionView(holding: holding)
                .environment(\.managedObjectContext, context)
        }
        .alert("Record Maturity", isPresented: $showRecordMaturity) {
            Button("Cancel", role: .cancel) {}
            Button("Record") { recordMaturity() }
        } message: {
            if let pos = position {
                Text("Mark this position as matured? Face value of \(pos.faceValue.asCurrency) will be noted as proceeds.")
            }
        }
        .sheet(item: $showMarkCoupon) { coupon in
            MarkCouponReceivedView(
                coupon: coupon,
                creditCash: $creditCashOnCoupon,
                onConfirm: { markCouponReceived(coupon) }
            )
        }
    }

    // MARK: - Summary Card

    private func summaryCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "POSITION SUMMARY") {
            VStack(spacing: 0) {
                // Instrument badge + name
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(holding.name)
                            .font(AppFont.body(14))
                            .foregroundColor(.textPrimary)
                        Text(pos.instrumentType.shortLabel)
                            .font(AppFont.mono(11, weight: .semibold))
                            .foregroundColor(pos.instrumentType.badgeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(pos.instrumentType.badgeColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Spacer()
                    if pos.isMatured {
                        Label("Matured", systemImage: "checkmark.circle.fill")
                            .font(AppFont.body(12, weight: .semibold))
                            .foregroundColor(.appGreen)
                    } else {
                        Text("\(pos.daysToMaturity)d left")
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(pos.daysToMaturity < 30 ? .appRed : .textSub)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                statRow("Face Value",      value: pos.faceValue.asCurrency)
                Divider().background(Color.appBorder)
                statRow("Purchase Price",  value: pos.purchasePrice.asCurrency)
                Divider().background(Color.appBorder)

                let discount = pos.discount
                HStack {
                    Text(discount >= 0 ? "Discount" : "Premium")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(abs(discount).asCurrency)
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(discount >= 0 ? .appGreen : .appRed)
                        Text("(\(abs(pos.discountPercent), specifier: "%.2f")%)")
                            .font(AppFont.mono(11))
                            .foregroundColor(.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let cusip = pos.cusip, !cusip.isEmpty {
                    Divider().background(Color.appBorder)
                    statRow("CUSIP", value: cusip)
                }

                Divider().background(Color.appBorder)
                statRow("Purchased",
                        value: pos.purchaseDate.formatted(.dateTime.month(.abbreviated).day().year()))
                Divider().background(Color.appBorder)
                statRow("Matures",
                        value: pos.maturityDate.formatted(.dateTime.month(.abbreviated).day().year()))
            }
        }
    }

    // MARK: - Yield Card

    private func yieldCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "YIELD") {
            VStack(spacing: 0) {
                statRow("YTM at Purchase",
                        value: "\((pos.ytmAtPurchase * 100).rounded(to: 3), specifier: "%.3f")%")

                if pos.instrumentType != .iBond {
                    let currentYTM = TreasuryEngine.ytmAtPurchase(
                        instrument: pos.instrumentType,
                        faceValue: pos.faceValue,
                        purchasePrice: pos.purchasePrice,
                        couponRate: pos.couponRate,
                        purchaseDate: Date(),
                        maturityDate: pos.maturityDate
                    )
                    Divider().background(Color.appBorder)
                    statRow("Current Est. YTM",
                            value: "\((currentYTM * 100).rounded(to: 3), specifier: "%.3f")%")
                }

                if pos.couponFrequency != .zero {
                    Divider().background(Color.appBorder)
                    statRow("Coupon Rate", value: "\((pos.couponRate * 100).rounded(to: 3), specifier: "%.3f")% annual")
                    Divider().background(Color.appBorder)
                    statRow("Per Payment", value: pos.perPaymentCouponAmount.asCurrency)
                    Divider().background(Color.appBorder)
                    statRow("Frequency",   value: pos.couponFrequency.displayName)
                }

                if pos.couponFrequency != .zero {
                    // Accrued interest (actual/actual)
                    if let accrued = computeAccruedInterest(pos) {
                        Divider().background(Color.appBorder)
                        statRow("Accrued Interest", value: accrued.asCurrency)
                    }
                }

                if pos.instrumentType == .tBill {
                    Divider().background(Color.appBorder)
                    let estVal = TreasuryEngine.tBillCurrentValue(
                        faceValue: pos.faceValue,
                        ytm: pos.ytmAtPurchase,
                        daysToMaturity: pos.daysToMaturity
                    )
                    statRow("Est. Current Value", value: estVal.asCurrency)
                }
            }
        }
    }

    // MARK: - TIPS Card

    private func tipsCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "INFLATION ADJUSTMENT (TIPS)") {
            VStack(spacing: 0) {
                if pos.inflationAdjustedPrincipal > 0 {
                    statRow("Original Principal", value: pos.faceValue.asCurrency)
                    Divider().background(Color.appBorder)
                    statRow("Adj. Principal", value: pos.inflationAdjustedPrincipal.asCurrency)
                    Divider().background(Color.appBorder)
                    let increase = pos.inflationAdjustedPrincipal - pos.faceValue
                    HStack {
                        Text("Inflation Gain")
                            .font(AppFont.body(13))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text(increase.asCurrency)
                            .font(AppFont.mono(13, weight: .semibold))
                            .foregroundColor(.appGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if let cpiDate = pos.lastCPIUpdateDate {
                        Divider().background(Color.appBorder)
                        statRow("Last CPI Update",
                                value: cpiDate.formatted(.dateTime.month(.abbreviated).year()))
                    }
                } else {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.appBlue)
                        Text("Enter current CPI-adjusted principal to track phantom income.")
                            .font(AppFont.body(12))
                            .foregroundColor(.textSub)
                    }
                    .padding(16)
                }

                if pos.tipsPhantomIncomeWarning {
                    Divider().background(Color.appBorder)
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.appGold)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TIPS Phantom Income")
                                .font(AppFont.body(13, weight: .semibold))
                                .foregroundColor(.appGold)
                            Text("Principal adjustments are federally taxable in the year earned, even though no cash is received. ~Estimated only — consult a tax advisor.")
                                .font(AppFont.body(11))
                                .foregroundColor(.textSub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - I-Bond Card

    private func iBondCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "I-BOND") {
            VStack(spacing: 0) {
                statRow("Fixed Rate",
                        value: "\((pos.fixedRate * 100).rounded(to: 3), specifier: "%.3f")%")
                Divider().background(Color.appBorder)
                statRow("Semiannual CPI Rate",
                        value: "\((pos.currentInflationRate * 100).rounded(to: 3), specifier: "%.3f")%")
                Divider().background(Color.appBorder)
                HStack {
                    Text("Composite Rate")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text("\((pos.compositeRate * 100).rounded(to: 3), specifier: "%.3f")%")
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.appGreen)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)
                let estVal = TreasuryEngine.iBondCurrentValue(
                    purchasePrice: pos.purchasePrice,
                    compositeRate: pos.compositeRate,
                    purchaseDate: pos.purchaseDate
                )
                statRow("Est. Current Value", value: estVal.asCurrency)

                Divider().background(Color.appBorder)

                // Lockup / penalty status
                if pos.isLocked, let lockup = pos.lockupExpiryDate {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.appRed)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Locked — Cannot Redeem")
                                .font(AppFont.body(13, weight: .semibold))
                                .foregroundColor(.appRed)
                            Text("Redeemable after \(lockup.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(AppFont.body(11))
                                .foregroundColor(.textMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else if pos.hasEarlyRedemptionPenalty, let penaltyFree = pos.penaltyFreeDate {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.appGold)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Early Redemption Penalty")
                                .font(AppFont.body(13, weight: .semibold))
                                .foregroundColor(.appGold)
                            Text("Redeeming before \(penaltyFree.formatted(.dateTime.month(.abbreviated).day().year())) forfeits the last 3 months of interest.")
                                .font(AppFont.body(11))
                                .foregroundColor(.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.appGreen)
                            .frame(width: 20)
                        Text("No early redemption penalty")
                            .font(AppFont.body(13))
                            .foregroundColor(.appGreen)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Divider().background(Color.appBorder)
                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.textMuted)
                        .frame(width: 20)
                    Text("I-Bond rates update every May and November. Update the composite rate manually when the Treasury announces new rates.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Coupon Card

    private func couponCard(_ pos: TreasuryPosition) -> some View {
        let upcoming = coupons.filter { !$0.isReceived }.prefix(4)
        let received = coupons.filter { $0.isReceived }
        let totalReceived = received.reduce(Decimal(0)) { $0 + $1.amount }

        return FormCard(title: "COUPON PAYMENTS") {
            VStack(spacing: 0) {
                statRow("Total Received", value: totalReceived.asCurrency)

                if !upcoming.isEmpty {
                    Divider().background(Color.appBorder)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("UPCOMING")
                            .font(AppFont.mono(10, weight: .semibold))
                            .foregroundColor(.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        ForEach(Array(upcoming), id: \.id) { coupon in
                            couponRow(coupon, received: false)
                            if coupon.id != upcoming.last?.id {
                                Divider().background(Color.appBorder).padding(.leading, 16)
                            }
                        }
                    }
                }

                if !received.isEmpty {
                    Divider().background(Color.appBorder)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("RECEIVED")
                            .font(AppFont.mono(10, weight: .semibold))
                            .foregroundColor(.textMuted)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        ForEach(received.prefix(6), id: \.id) { coupon in
                            couponRow(coupon, received: true)
                            Divider().background(Color.appBorder).padding(.leading, 16)
                        }
                    }
                }

                if coupons.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.appBlue)
                        Text("No coupon schedule generated yet. This will appear after setup.")
                            .font(AppFont.body(12))
                            .foregroundColor(.textSub)
                    }
                    .padding(16)
                }
            }
        }
    }

    private func couponRow(_ coupon: CouponPayment, received: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: received ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(received ? .appGreen : .textMuted)

            VStack(alignment: .leading, spacing: 3) {
                Text(coupon.scheduledDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(received ? .textMuted : .textPrimary)
                if received, let recDate = coupon.receivedDate {
                    Text("Received \(recDate.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
            }

            Spacer()

            Text(coupon.amount.asCurrency)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(received ? .textMuted : .appGreen)

            if !received {
                Button {
                    showMarkCoupon = coupon
                } label: {
                    Text("Mark")
                        .font(AppFont.body(12, weight: .semibold))
                        .foregroundColor(.appBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Tax Card

    private func taxCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "TAX TREATMENT") {
            VStack(spacing: 0) {
                taxRow(label: "Federal Income Tax", exempt: false)
                Divider().background(Color.appBorder)
                taxRow(label: "State Income Tax",   exempt: pos.isStateExempt)
                Divider().background(Color.appBorder)
                taxRow(label: "City / Local Tax",   exempt: pos.isCityExempt)
                Divider().background(Color.appBorder)
                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                    Text("US Treasury interest is exempt from state and local taxes. ~Estimated only — consult a tax advisor.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func taxRow(label: String, exempt: Bool) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Label(exempt ? "Exempt" : "Taxable",
                  systemImage: exempt ? "checkmark.circle.fill" : "xmark.circle")
                .font(AppFont.body(12, weight: .semibold))
                .foregroundColor(exempt ? .appGreen : .textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Maturity Card

    private func maturityCard(_ pos: TreasuryPosition) -> some View {
        FormCard(title: "MATURITY") {
            VStack(spacing: 0) {
                if pos.isMatured {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.appGreen)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Matured")
                                .font(AppFont.body(14, weight: .semibold))
                                .foregroundColor(.appGreen)
                            if let at = pos.maturedAt {
                                Text(at.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(AppFont.body(12))
                                    .foregroundColor(.textMuted)
                            }
                            if pos.maturityProceeds > 0 {
                                Text("Proceeds: \(pos.maturityProceeds.asCurrency)")
                                    .font(AppFont.mono(12, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                            }
                        }
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "calendar.badge.clock")
                                .font(.system(size: 28))
                                .foregroundColor(.appBlue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(pos.daysToMaturity) days remaining")
                                    .font(AppFont.body(15, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Text("Matures \(pos.maturityDate.formatted(.dateTime.month(.abbreviated).day().year()))")
                                    .font(AppFont.body(12))
                                    .foregroundColor(.textSub)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        if pos.daysToMaturity == 0 || pos.maturityDate <= Date() {
                            Divider().background(Color.appBorder)
                            Button {
                                showRecordMaturity = true
                            } label: {
                                Text("Record Maturity")
                                    .font(AppFont.body(15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.appGreen)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        } else {
                            Divider().background(Color.appBorder).padding(.bottom, 8)
                            Text("Principal of \(pos.faceValue.asCurrency) will be returned at maturity.")
                                .font(AppFont.body(12))
                                .foregroundColor(.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 14)
                        }
                    }
                }
            }
        }
    }

    // MARK: - No Position Card (pre-Phase 12 holdings)

    private var noPositionCard: some View {
        FormCard(title: "TREASURY DETAILS") {
            VStack(spacing: 14) {
                Image(systemName: "building.columns")
                    .font(.system(size: 34))
                    .foregroundColor(.textMuted)
                Text("This holding was added before detailed treasury tracking was available.")
                    .font(AppFont.body(13))
                    .foregroundColor(.textSub)
                    .multilineTextAlignment(.center)
                Button {
                    showAddTreasury = true
                } label: {
                    Text("Set Up Treasury Details")
                        .font(AppFont.body(14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.appBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Accrued Interest Computation

    /// Returns accrued interest for coupon-bearing instruments using the coupon schedule.
    private func computeAccruedInterest(_ pos: TreasuryPosition) -> Decimal? {
        guard pos.couponFrequency != .zero else { return nil }
        let today = Date()
        let sortedCoupons = coupons.sorted { $0.scheduledDate < $1.scheduledDate }
        let lastCoupon = sortedCoupons.last(where: { $0.scheduledDate <= today })
        let nextCoupon = sortedCoupons.first(where: { $0.scheduledDate > today })

        let lastDate: Date
        if let lc = lastCoupon {
            lastDate = lc.scheduledDate
        } else {
            lastDate = pos.purchaseDate  // before first coupon: accrue from purchase
        }
        guard let nc = nextCoupon else { return nil }

        let cal = Calendar.current
        let daysSinceLast = cal.dateComponents([.day], from: lastDate, to: today).day ?? 0
        let daysInPeriod  = cal.dateComponents([.day], from: lastDate, to: nc.scheduledDate).day ?? 0
        guard daysInPeriod > 0 else { return nil }

        return TreasuryEngine.accruedInterest(
            faceValue: pos.effectivePrincipal,
            couponRate: pos.couponRate,
            paymentsPerYear: pos.couponFrequency.paymentsPerYear,
            daysSinceLastCoupon: daysSinceLast,
            daysInCouponPeriod: daysInPeriod
        )
    }

    // MARK: - Actions

    private func recordMaturity() {
        guard let pos = position else { return }
        pos.isMatured = true
        pos.maturedAt = Date()
        pos.maturityProceeds = pos.faceValue
        try? context.save()
        // Credit face value to cash
        CashLedgerService.credit(amount: pos.faceValue, note: "Treasury maturity proceeds — \(holding.symbol)", in: context)
        try? context.save()
    }

    private func markCouponReceived(_ coupon: CouponPayment) {
        coupon.markReceived(in: context, creditCash: creditCashOnCoupon)
        try? context.save()
        showMarkCoupon = nil
    }
}

// MARK: - TreasuryInstrument badge color extension

extension TreasuryInstrument {
    var badgeColor: Color {
        switch self {
        case .tBill:  return .appBlue
        case .tNote:  return .appGreen
        case .tBond:  return Color(red: 0.3, green: 0.7, blue: 0.5)
        case .tips:   return .appGold
        case .iBond:  return .appRed
        }
    }
}

// MARK: - MarkCouponReceivedView

private struct MarkCouponReceivedView: View {
    let coupon: CouponPayment
    @Binding var creditCash: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                VStack(spacing: 16) {
                    FormCard(title: "MARK COUPON RECEIVED") {
                        VStack(spacing: 0) {
                            statRow("Amount",         value: coupon.amount.asCurrency)
                            Divider().background(Color.appBorder)
                            statRow("Scheduled Date",
                                    value: coupon.scheduledDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            Divider().background(Color.appBorder)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add to Cash Balance")
                                        .font(AppFont.body(14))
                                        .foregroundColor(.textPrimary)
                                    Text("Credit \(coupon.amount.asCurrency) to your cash position")
                                        .font(AppFont.body(11))
                                        .foregroundColor(.textSub)
                                }
                                Spacer()
                                Toggle("", isOn: $creditCash)
                                    .tint(.appGreen)
                                    .labelsHidden()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }

                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text("Confirm")
                            .font(AppFont.body(16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.appGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(16)
            }
            .navigationTitle("Coupon Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
