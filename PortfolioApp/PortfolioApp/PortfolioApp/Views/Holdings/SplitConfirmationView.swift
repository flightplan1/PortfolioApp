import SwiftUI
import CoreData

// MARK: - SplitConfirmationView
// Presented as a sheet when SplitService detects an unprocessed split.
// Shows ratio, before/after share counts, and Apply / Skip actions.
// For reverse splits, also shows the fractional cash-out option explanation.

struct SplitConfirmationView: View {

    let pending: PendingSplit
    let onApply: () -> Void
    let onSkip: () -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest private var openLots: FetchedResults<Lot>

    @State private var isSaving = false
    @State private var showError = false
    @State private var errorMessage = ""

    init(pending: PendingSplit, onApply: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.pending = pending
        self.onApply = onApply
        self.onSkip = onSkip
        _openLots = FetchRequest(fetchRequest: Lot.openLots(for: pending.holding.id), animation: .none)
    }

    // MARK: - Computed

    private var currentShares: Decimal {
        openLots.reduce(0) { $0 + $1.remainingQty }
    }

    private var sharesAfter: Decimal {
        (currentShares * pending.multiplier).rounded(to: 6)
    }

    private var fractionalShares: Decimal {
        let whole = Decimal(Int(truncating: sharesAfter as NSDecimalNumber))
        return sharesAfter - whole
    }

    private var hasFractional: Bool {
        !pending.isForward && fractionalShares > 0
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        headerCard
                        sharesCard
                        if !pending.isForward {
                            reverseSplitWarning
                        }
                        if hasFractional {
                            fractionalCard
                        }
                        actionButtons
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Stock Split Detected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Skip") { skip() }
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

    // MARK: - Header Card

    private var headerCard: some View {
        FormCard(title: "SPLIT DETAILS") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(pending.holding.symbol)
                                .font(AppFont.mono(18, weight: .bold))
                                .foregroundColor(.textPrimary)
                            AssetTypeChip(type: pending.holding.assetType)
                        }
                        Text(pending.holding.name)
                            .font(AppFont.body(13))
                            .foregroundColor(.textSub)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(pending.ratioString)
                            .font(AppFont.mono(24, weight: .bold))
                            .foregroundColor(pending.isForward ? .appGreen : .appRed)
                        Text(pending.isForward ? "Forward Split" : "Reverse Split")
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                    }
                }
                .padding(16)

                Divider().background(Color.appBorder)

                HStack {
                    Text("Effective Date")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text(pending.splitDate.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Shares Card

    private var sharesCard: some View {
        FormCard(title: "YOUR POSITION") {
            VStack(spacing: 0) {
                sharesRow(label: "Shares Before", value: currentShares, color: .textPrimary)
                Divider().background(Color.appBorder)
                sharesRow(label: "Split Ratio", value: nil, ratioText: "× \(pending.multiplier.asQuantity(maxDecimalPlaces: 4))", color: .textSub)
                Divider().background(Color.appBorder)
                sharesRow(label: "Shares After", value: sharesAfter, color: pending.isForward ? .appGreen : .appRed)

                Divider().background(Color.appBorder)

                HStack {
                    Text("Cost Basis")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text("Unchanged (IRS rule)")
                        .font(AppFont.mono(13))
                        .foregroundColor(.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func sharesRow(label: String, value: Decimal?, ratioText: String? = nil, color: Color) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            if let v = value {
                Text(v.asQuantity(maxDecimalPlaces: 6))
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(color)
            } else if let t = ratioText {
                Text(t)
                    .font(AppFont.mono(13))
                    .foregroundColor(color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Reverse Split Warning

    private var reverseSplitWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.appRed)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reverse Split")
                    .font(AppFont.body(13, weight: .semibold))
                    .foregroundColor(.appRed)
                Text("You will receive fewer shares at a proportionally higher price per share. Total position value is unchanged.")
                    .font(AppFont.body(12))
                    .foregroundColor(.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color.appRed.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appRed.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Fractional Shares Card

    private var fractionalCard: some View {
        FormCard(title: "FRACTIONAL SHARES") {
            VStack(spacing: 0) {
                HStack {
                    Text("Fractional shares")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text(fractionalShares.asQuantity(maxDecimalPlaces: 6))
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.appGold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)

                Text("Brokers typically cash out fractional shares after a reverse split. Record any cash payment you received in your Cash position separately.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                apply()
            } label: {
                HStack {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Apply \(pending.ratioString) Split")
                            .font(AppFont.body(16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(pending.isForward ? Color.appGreen : Color.appRed)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isSaving)

            Button {
                skip()
            } label: {
                Text("Skip — Not My Broker's Split")
                    .font(AppFont.body(14))
                    .foregroundColor(.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
    }

    // MARK: - Actions

    private func apply() {
        isSaving = true
        do {
            try SplitService.shared.applySplit(pending, in: context)
            onApply()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func skip() {
        SplitService.shared.dismissPendingSplit(pending)
        onSkip()
        dismiss()
    }
}

// MARK: - Manual Split Entry View

struct AddSplitView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var numerator:   String = "2"
    @State private var denominator: String = "1"
    @State private var splitDate:   Date   = Date()
    @State private var showDatePicker = false
    @State private var isSaving    = false
    @State private var showError   = false
    @State private var errorMessage = ""

    private var num: Int? { Int(numerator) }
    private var den: Int? { Int(denominator) }
    private var multiplier: Decimal? {
        guard let n = num, let d = den, n > 0, d > 0 else { return nil }
        return Decimal(n) / Decimal(d)
    }
    private var isForward: Bool { (multiplier ?? 1) >= 1 }
    private var canSave: Bool { num != nil && den != nil && multiplier != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FormCard(title: "SPLIT DETAILS") {
                            VStack(spacing: 0) {
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

                                datePickerRow(label: "Split Date", date: $splitDate, isExpanded: $showDatePicker)

                                Divider().background(Color.appBorder)

                                HStack(spacing: 12) {
                                    FormField(label: "New Shares", placeholder: "2") {
                                        TextField("2", text: $numerator)
                                            .keyboardType(.numberPad)
                                    }
                                    FormField(label: "Old Shares", placeholder: "1") {
                                        TextField("1", text: $denominator)
                                            .keyboardType(.numberPad)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)

                                if let m = multiplier {
                                    Divider().background(Color.appBorder)
                                    HStack {
                                        Text("Split type")
                                            .font(AppFont.body(13))
                                            .foregroundColor(.textSub)
                                        Spacer()
                                        Text(isForward ? "Forward (\(m.asQuantity(maxDecimalPlaces: 4))×)" : "Reverse (\(m.asQuantity(maxDecimalPlaces: 4))×)")
                                            .font(AppFont.mono(13, weight: .semibold))
                                            .foregroundColor(isForward ? .appGreen : .appRed)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                }
                            }
                        }

                        Button {
                            save()
                        } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                else { Text("Apply Split").font(AppFont.body(16, weight: .semibold)) }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(canSave ? Color.appBlue : Color.appBorder)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!canSave || isSaving)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Historical Split")
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

    private func save() {
        guard let n = num, let d = den else { return }
        isSaving = true
        do {
            try SplitService.shared.addManualSplit(
                holding: holding,
                splitDate: splitDate,
                numerator: n,
                denominator: d,
                in: context
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func datePickerRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
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
