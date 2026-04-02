import SwiftUI
import CoreData

// MARK: - PriceAlertsView
// Sheet presented from PositionDetailView's bell toolbar button.
// Shows active and triggered alerts for a holding; lets user add/delete.

struct PriceAlertsView: View {

    let holding: Holding

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss

    @FetchRequest private var alerts: FetchedResults<PriceAlert>

    @State private var targetPriceInput = ""
    @State private var direction: AlertDirection = .above
    @State private var showError = false
    @State private var errorMessage = ""

    init(holding: Holding) {
        self.holding = holding
        _alerts = FetchRequest(fetchRequest: PriceAlert.all(for: holding.id), animation: .default)
    }

    // MARK: - Computed

    private var activeAlerts: [PriceAlert]    { alerts.filter { !$0.isTriggered } }
    private var triggeredAlerts: [PriceAlert] { alerts.filter {  $0.isTriggered } }

    private var canAdd: Bool {
        guard let price = Decimal(string: targetPriceInput), price > 0 else { return false }
        return true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        addAlertCard
                        if !activeAlerts.isEmpty {
                            activeAlertsCard
                        }
                        if !triggeredAlerts.isEmpty {
                            triggeredAlertsCard
                        }
                        if alerts.isEmpty {
                            emptyState
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Price Alerts — \(holding.symbol)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
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

    // MARK: - Add Alert Card

    private var addAlertCard: some View {
        FormCard(title: "NEW ALERT") {
            VStack(spacing: 0) {
                // Direction picker
                HStack {
                    Text("Trigger when price is")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Picker("", selection: $direction) {
                        ForEach(AlertDirection.allCases, id: \.self) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)

                FormField(label: "Target Price", placeholder: "0.00") {
                    TextField("0.00", text: $targetPriceInput)
                        .keyboardType(.decimalPad)
                }

                Divider().background(Color.appBorder)

                Button {
                    addAlert()
                } label: {
                    Text("Add Alert")
                        .font(AppFont.body(15, weight: .semibold))
                        .foregroundColor(canAdd ? .white : .textMuted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(canAdd ? Color.appBlue : Color.appBorder)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!canAdd)
                .padding(16)
            }
        }
    }

    // MARK: - Active Alerts Card

    private var activeAlertsCard: some View {
        FormCard(title: "ACTIVE") {
            VStack(spacing: 0) {
                ForEach(Array(activeAlerts.enumerated()), id: \.element.id) { index, alert in
                    alertRow(alert, triggered: false)
                    if index < activeAlerts.count - 1 {
                        Divider().background(Color.appBorder)
                    }
                }
            }
        }
    }

    // MARK: - Triggered Alerts Card

    private var triggeredAlertsCard: some View {
        FormCard(title: "TRIGGERED") {
            VStack(spacing: 0) {
                ForEach(Array(triggeredAlerts.enumerated()), id: \.element.id) { index, alert in
                    alertRow(alert, triggered: true)
                    if index < triggeredAlerts.count - 1 {
                        Divider().background(Color.appBorder)
                    }
                }
            }
        }
    }

    private func alertRow(_ alert: PriceAlert, triggered: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: alert.direction.icon)
                .font(.system(size: 16))
                .foregroundColor(triggered ? .textMuted : (alert.direction == .above ? .appGreen : .appRed))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(alert.direction.label) \(alert.targetPrice.asCurrency)")
                    .font(AppFont.mono(13, weight: .semibold))
                    .foregroundColor(triggered ? .textMuted : .textPrimary)
                if triggered, let at = alert.triggeredAt {
                    Text("Triggered \(at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                } else {
                    Text("Set \(alert.createdAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
            }

            Spacer()

            Button {
                deleteAlert(alert)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundColor(.textMuted)
            Text("No alerts set")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Actions

    private func addAlert() {
        guard let price = Decimal(string: targetPriceInput), price > 0 else { return }
        let alert = PriceAlert.create(in: context, holding: holding, targetPrice: price, direction: direction)
        do {
            try context.save()
            targetPriceInput = ""
            PriceAlertService.shared.requestPermissionIfNeeded()
            _ = alert
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteAlert(_ alert: PriceAlert) {
        context.delete(alert)
        try? context.save()
    }
}
