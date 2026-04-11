import SwiftUI
import CoreData

struct EditHoldingView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest private var openLots: FetchedResults<Lot>

    @State private var name: String = ""
    @State private var isRetirementAccount: Bool = false
    @State private var newBalanceText: String = ""
    @State private var showError = false
    @State private var errorMessage = ""

    init(holding: Holding) {
        self.holding = holding
        _openLots = FetchRequest(fetchRequest: Lot.openLots(for: holding.id), animation: .none)
    }

    private var isCash: Bool { holding.assetType == .cash }

    private var currentBalance: Decimal {
        openLots.reduce(Decimal(0)) { $0 + $1.remainingQty }
    }

    private var newBalance: Decimal? {
        guard let v = Decimal(string: newBalanceText), v >= 0 else { return nil }
        return v
    }

    private var canSave: Bool {
        let nameOk = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if isCash {
            return nameOk && (newBalanceText.isEmpty || newBalance != nil)
        }
        return nameOk
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        FormCard(title: "HOLDING DETAILS") {
                            VStack(spacing: 0) {
                                // Symbol (read-only)
                                HStack {
                                    Text("Symbol")
                                        .font(AppFont.body(14))
                                        .foregroundColor(.textSub)
                                    Spacer()
                                    Text(holding.symbol)
                                        .font(AppFont.mono(14, weight: .semibold))
                                        .foregroundColor(.textMuted)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

                                Divider().background(Color.appBorder)

                                // Name (editable)
                                HStack {
                                    Text("Label")
                                        .font(AppFont.body(14))
                                        .foregroundColor(.textSub)
                                    Spacer()
                                    TextField(holding.symbol, text: $name)
                                        .font(AppFont.mono(14))
                                        .foregroundColor(.textPrimary)
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: 200)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)

                                Divider().background(Color.appBorder)

                                // Retirement account toggle
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Retirement Account")
                                            .font(AppFont.body(14))
                                            .foregroundColor(.textPrimary)
                                        Text("IRA, Roth, 401k — suppresses tax estimates")
                                            .font(AppFont.body(11))
                                            .foregroundColor(.textMuted)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $isRetirementAccount)
                                        .tint(.appPurple)
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                            }
                        }

                        if isCash {
                            FormCard(title: "CASH BALANCE") {
                                VStack(spacing: 0) {
                                    // Current balance (read-only)
                                    HStack {
                                        Text("Current Balance")
                                            .font(AppFont.body(14))
                                            .foregroundColor(.textSub)
                                        Spacer()
                                        Text(currentBalance.asCurrency)
                                            .font(AppFont.mono(14, weight: .semibold))
                                            .foregroundColor(.appGreen)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)

                                    Divider().background(Color.appBorder)

                                    // New balance input
                                    HStack {
                                        Text("Set Balance To")
                                            .font(AppFont.body(14))
                                            .foregroundColor(.textSub)
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Text("$")
                                                .font(AppFont.mono(14))
                                                .foregroundColor(.textMuted)
                                            TextField(currentBalance.formatted(), text: $newBalanceText)
                                                .font(AppFont.mono(14))
                                                .foregroundColor(.textPrimary)
                                                .keyboardType(.decimalPad)
                                                .multilineTextAlignment(.trailing)
                                                .frame(maxWidth: 140)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)

                                    if let nb = newBalance, nb != currentBalance {
                                        Divider().background(Color.appBorder)
                                        let diff = nb - currentBalance
                                        HStack {
                                            Image(systemName: diff >= 0 ? "arrow.up.circle" : "arrow.down.circle")
                                                .font(.system(size: 12))
                                                .foregroundColor(diff >= 0 ? .appGreen : .appRed)
                                            Text("\(diff >= 0 ? "+" : "")\(diff.asCurrency) adjustment")
                                                .font(AppFont.mono(12))
                                                .foregroundColor(diff >= 0 ? .appGreen : .appRed)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit \(holding.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveChanges()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(canSave ? .appBlue : .textMuted)
                    .disabled(!canSave)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                name = holding.name
                isRetirementAccount = holding.isRetirementAccount
            }
        }
    }

    private func saveChanges() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        holding.name = trimmed
        holding.isRetirementAccount = isRetirementAccount

        // Apply balance adjustment for cash holdings
        if isCash, let nb = newBalance, nb != currentBalance {
            setBalance(to: nb)
        }

        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Clears all open lots and creates a single lot at the target balance.
    private func setBalance(to target: Decimal) {
        for lot in openLots { lot.softDelete() }
        if target > 0 {
            CashLedgerService.credit(amount: target, date: Date(), sourceNote: "Balance adjustment", in: context)
        }
    }
}
