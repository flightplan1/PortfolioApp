import SwiftUI
import CoreData

struct WithdrawCashView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var withdrawDate = Date()
    @State private var showDatePicker = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false

    private let availableBalance: Decimal

    init(availableBalance: Decimal) {
        self.availableBalance = availableBalance
    }

    private var amount: Decimal? {
        guard let v = Decimal(string: amountText), v > 0 else { return nil }
        return v
    }

    private var exceedsBalance: Bool {
        guard let amt = amount else { return false }
        return amt > availableBalance
    }

    private var canSave: Bool { amount != nil && !exceedsBalance }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        // Available balance banner
                        HStack {
                            Text("Available Balance")
                                .font(AppFont.body(13))
                                .foregroundColor(.textSub)
                            Spacer()
                            Text(availableBalance.asCurrency)
                                .font(AppFont.mono(14, weight: .semibold))
                                .foregroundColor(.appGreen)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.appGreen.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        FormCard(title: "WITHDRAWAL DETAILS") {
                            VStack(spacing: 0) {
                                // Amount
                                HStack {
                                    Text("$")
                                        .font(AppFont.mono(16, weight: .semibold))
                                        .foregroundColor(.textSub)
                                    TextField("Amount", text: $amountText)
                                        .font(AppFont.mono(16))
                                        .foregroundColor(exceedsBalance ? .appRed : .textPrimary)
                                        .keyboardType(.decimalPad)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

                                if exceedsBalance {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.appRed)
                                        Text("Exceeds available balance")
                                            .font(AppFont.body(11))
                                            .foregroundColor(.appRed)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                                }

                                Divider().background(Color.appBorder)

                                // Date
                                Button {
                                    withAnimation { showDatePicker.toggle() }
                                } label: {
                                    HStack {
                                        Text("Date")
                                            .font(AppFont.body(14))
                                            .foregroundColor(.textSub)
                                        Spacer()
                                        Text(withdrawDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                            .font(AppFont.mono(14))
                                            .foregroundColor(.textPrimary)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.textMuted)
                                            .rotationEffect(.degrees(showDatePicker ? 180 : 0))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                }
                                .buttonStyle(.plain)

                                if showDatePicker {
                                    DatePicker("", selection: $withdrawDate, in: ...Date(), displayedComponents: .date)
                                        .datePickerStyle(.graphical)
                                        .tint(.appBlue)
                                        .padding(.horizontal, 8)
                                }
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                            Text("Withdrawals reduce your cash balance using FIFO — oldest lots are debited first.")
                                .font(AppFont.body(12))
                                .foregroundColor(.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Withdraw Cash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appBlue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        saveWithdrawal()
                    } label: {
                        if isSaving {
                            ProgressView().tint(.appBlue)
                        } else {
                            Text("Confirm")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(canSave ? .appBlue : .textMuted)
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .alert("Invalid Input", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func saveWithdrawal() {
        guard let amt = amount else {
            errorMessage = "Enter a valid amount greater than zero."
            showError = true
            return
        }
        guard amt <= availableBalance else {
            errorMessage = "Amount exceeds available cash balance of \(availableBalance.asCurrency)."
            showError = true
            return
        }
        isSaving = true
        CashLedgerService.withdraw(amount: amt, date: withdrawDate, in: context)
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
        isSaving = false
    }
}
