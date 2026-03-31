import SwiftUI
import CoreData

struct DepositCashView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var depositDate = Date()
    @State private var showDatePicker = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false

    private var amount: Decimal? {
        guard let v = Decimal(string: amountText), v > 0 else { return nil }
        return v
    }

    private var canSave: Bool { amount != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FormCard(title: "DEPOSIT DETAILS") {
                            VStack(spacing: 0) {
                                // Amount
                                HStack {
                                    Text("$")
                                        .font(AppFont.mono(16, weight: .semibold))
                                        .foregroundColor(.textSub)
                                    TextField("Amount", text: $amountText)
                                        .font(AppFont.mono(16))
                                        .foregroundColor(.textPrimary)
                                        .keyboardType(.decimalPad)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

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
                                        Text(depositDate.formatted(.dateTime.month(.abbreviated).day().year()))
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
                                    DatePicker("", selection: $depositDate, in: ...Date(), displayedComponents: .date)
                                        .datePickerStyle(.graphical)
                                        .tint(.appBlue)
                                        .padding(.horizontal, 8)
                                }
                            }
                        }

                        // Info note
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.textMuted)
                            Text("Cash deposits are tracked at $1.00/unit. The balance appears in your Holdings and is included in portfolio totals.")
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
            .navigationTitle("Deposit Cash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.appBlue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        saveDeposit()
                    } label: {
                        if isSaving {
                            ProgressView().tint(.appBlue)
                        } else {
                            Text("Save")
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

    private func saveDeposit() {
        guard let amt = amount else {
            errorMessage = "Enter a valid amount greater than zero."
            showError = true
            return
        }
        isSaving = true
        CashLedgerService.credit(amount: amt, date: depositDate, in: context)
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

#Preview {
    DepositCashView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
