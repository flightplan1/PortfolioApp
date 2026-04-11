import SwiftUI
import CoreData

struct EditCashEntryView: View {

    let lot: Lot

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var amountText: String = ""
    @State private var entryDate: Date = Date()
    @State private var showDatePicker = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showDeleteConfirm = false
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
                        FormCard(title: "EDIT CASH ENTRY") {
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
                                        Text(entryDate.formatted(.dateTime.month(.abbreviated).day().year()))
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
                                    DatePicker("", selection: $entryDate, in: ...Date(), displayedComponents: .date)
                                        .datePickerStyle(.graphical)
                                        .tint(.appBlue)
                                        .colorScheme(.dark)
                                        .padding(.horizontal, 8)
                                        .onChange(of: entryDate) { _, _ in
                                            withAnimation { showDatePicker = false }
                                        }
                                }
                            }
                        }

                        // Delete button
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Entry")
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
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Edit Cash Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        saveChanges()
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
            .alert("Delete Entry?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { deleteEntry() }
            } message: {
                Text("This will permanently remove this cash entry. This action cannot be undone.")
            }
            .onAppear {
                amountText = lot.remainingQty.formatted()
                entryDate = lot.purchaseDate
            }
        }
    }

    private func saveChanges() {
        guard let amt = amount else {
            errorMessage = "Enter a valid amount greater than zero."
            showError = true
            return
        }
        isSaving = true
        lot.originalQty = amt
        lot.splitAdjustedQty = amt
        lot.remainingQty = amt
        lot.totalCostBasis = amt   // costBasisPerShare = $1.00, so totalCostBasis = amount
        lot.purchaseDate = entryDate
        do {
            try context.save()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            showError = true
        }
        isSaving = false
    }

    private func deleteEntry() {
        lot.softDelete()
        try? context.save()
        dismiss()
    }
}
