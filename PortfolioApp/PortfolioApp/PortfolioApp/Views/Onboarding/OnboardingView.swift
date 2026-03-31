import SwiftUI

// MARK: - OnboardingView

struct OnboardingView: View {

    @EnvironmentObject private var taxProfileManager: TaxProfileManager
    @Environment(\.dismiss) private var dismiss

    // Step state
    @State private var step: Int = 1

    // Step 1 — Filing status
    @State private var filingStatus: FilingStatus = .single

    // Step 2 — Income
    @State private var incomeText: String = ""

    // Step 3 — Location
    @State private var selectedState: String = ""
    @State private var selectedCity:  String = ""
    @State private var isResident: Bool = true
    @State private var stateSearchText: String = ""

    // Step 4 — Disclaimer acknowledgement
    @State private var disclaimerAcknowledged: Bool = false

    private let totalSteps = 3

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.appBorder)
                stepProgress
                ScrollView {
                    VStack(spacing: 20) {
                        stepContent
                    }
                    .padding(20)
                    .padding(.bottom, 32)
                }
                bottomBar
            }
        }
        .onAppear {
            // Pre-fill from existing profile if editing
            let p = taxProfileManager.profile
            filingStatus  = p.filingStatus
            incomeText    = p.ordinaryIncome > 0
                ? NSDecimalNumber(decimal: p.ordinaryIncome).stringValue
                : ""
            selectedState = p.state ?? ""
            selectedCity  = p.city  ?? ""
            isResident    = p.isResident
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("TAX PROFILE")
                    .font(AppFont.mono(11, weight: .bold))
                    .foregroundColor(.textMuted)
                Text(stepTitle)
                    .font(AppFont.body(18, weight: .semibold))
                    .foregroundColor(.textPrimary)
            }
            Spacer()
            if taxProfileManager.isProfileComplete {
                Button("Cancel") { dismiss() }
                    .font(AppFont.body(15))
                    .foregroundColor(.textSub)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var stepTitle: String {
        switch step {
        case 1: return "Filing Status"
        case 2: return "Annual Income"
        case 3: return "Location"
        case 4: return "Confirm & Accept"
        default: return ""
        }
    }

    // MARK: - Progress bar

    private var stepProgress: some View {
        HStack(spacing: 6) {
            ForEach(1...totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= min(step, totalSteps) ? Color.appBlue : Color.appBorder)
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.25), value: step)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Step content router

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: step1FilingStatus
        case 2: step2Income
        case 3: step3Location
        case 4: step4Disclaimer
        default: EmptyView()
        }
    }

    // MARK: - Step 1: Filing Status

    private var step1FilingStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How do you file your taxes?")
                .font(AppFont.body(14))
                .foregroundColor(.textSub)

            VStack(spacing: 8) {
                ForEach(FilingStatus.allCases) { status in
                    filingStatusCard(status)
                }
            }

            Spacer(minLength: 16)
            Text("Your filing status determines your federal tax bracket thresholds.")
                .font(AppFont.body(12))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 4)
        }
    }

    private func filingStatusCard(_ status: FilingStatus) -> some View {
        Button {
            filingStatus = status
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(filingStatus == status ? Color.appBlue : Color.appBorder, lineWidth: 2)
                        .frame(width: 20, height: 20)
                    if filingStatus == status {
                        Circle()
                            .fill(Color.appBlue)
                            .frame(width: 11, height: 11)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.shortName)
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(status.displayName)
                        .font(AppFont.body(12))
                        .foregroundColor(.textSub)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(filingStatus == status ? Color.appBlue.opacity(0.08) : Color.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(filingStatus == status ? Color.appBlue.opacity(0.4) : Color.appBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Income

    private var step2Income: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What is your estimated annual ordinary income?")
                    .font(AppFont.body(14))
                    .foregroundColor(.textSub)
                Text("Include wages, salary, and business income — but NOT capital gains.")
                    .font(AppFont.body(12))
                    .foregroundColor(.textMuted)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ANNUAL INCOME (USD)")
                    .font(AppFont.mono(10, weight: .semibold))
                    .foregroundColor(.textMuted)

                HStack {
                    Text("$")
                        .font(AppFont.mono(22, weight: .semibold))
                        .foregroundColor(.textSub)
                    TextField("70,000", text: $incomeText)
                        .font(AppFont.mono(22, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .keyboardType(.numberPad)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.appBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Quick-select buttons
            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK SELECT")
                    .font(AppFont.mono(10, weight: .semibold))
                    .foregroundColor(.textMuted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(["50000", "75000", "100000", "150000", "200000", "300000"], id: \.self) { val in
                        Button {
                            incomeText = val
                        } label: {
                            let k = (Int(val) ?? 0) / 1000
                            Text("$\(k)k")
                                .font(AppFont.mono(12, weight: .medium))
                                .foregroundColor(incomeText == val ? .white : .textSub)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(incomeText == val ? Color.appBlue : Color.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.appBorder, lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("This is used to determine your effective marginal tax bracket for short-term capital gains. It does not affect long-term gain rates directly.")
                .font(AppFont.body(12))
                .foregroundColor(.textMuted)
        }
    }

    // MARK: - Step 3: Location

    private var step3Location: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Where do you file state taxes?")
                .font(AppFont.body(14))
                .foregroundColor(.textSub)

            statePicker
            if !selectedState.isEmpty { cityPicker }
            if !selectedState.isEmpty { residencyToggle }
        }
    }

    private var statePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STATE")
                .font(AppFont.mono(10, weight: .semibold))
                .foregroundColor(.textMuted)

            let allStates = TaxRatesLoader.allStatesIncludingNoTax()

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(.textMuted)
                    TextField("Search state...", text: $stateSearchText)
                        .font(AppFont.body(14))
                        .foregroundColor(.textPrimary)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider().background(Color.appBorder)

                let filtered = stateSearchText.isEmpty
                    ? allStates
                    : allStates.filter { $0.name.localizedCaseInsensitiveContains(stateSearchText) || $0.code.localizedCaseInsensitiveContains(stateSearchText) }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered, id: \.code) { state in
                            Button {
                                selectedState = state.code
                                selectedCity  = ""    // reset city when state changes
                                stateSearchText = ""
                            } label: {
                                HStack {
                                    Text(state.code)
                                        .font(AppFont.mono(12, weight: .bold))
                                        .foregroundColor(.appBlue)
                                        .frame(width: 30, alignment: .leading)
                                    Text(state.name)
                                        .font(AppFont.body(14))
                                        .foregroundColor(.textPrimary)
                                    Spacer()
                                    if selectedState == state.code {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.appBlue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .background(selectedState == state.code ? Color.appBlue.opacity(0.06) : Color.clear)

                            if state.code != filtered.last?.code {
                                Divider().background(Color.appBorder).padding(.leading, 12)
                            }
                        }
                    }
                }
            }
            .background(Color.surface)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxHeight: 280)
        }
    }

    private var cityPicker: some View {
        let cities = TaxRatesLoader.cities(for: selectedState)
        guard !cities.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("CITY (OPTIONAL)")
                    .font(AppFont.mono(10, weight: .semibold))
                    .foregroundColor(.textMuted)

                VStack(spacing: 0) {
                    Button {
                        selectedCity = ""
                    } label: {
                        HStack {
                            Text("No city tax")
                                .font(AppFont.body(14))
                                .foregroundColor(.textSub)
                            Spacer()
                            if selectedCity.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.appBlue)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(selectedCity.isEmpty ? Color.appBlue.opacity(0.06) : Color.clear)

                    Divider().background(Color.appBorder).padding(.leading, 12)

                    ForEach(cities, id: \.key) { city in
                        Button {
                            selectedCity = city.key
                        } label: {
                            HStack {
                                Text(city.name)
                                    .font(AppFont.body(14))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                if selectedCity == city.key {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.appBlue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .background(selectedCity == city.key ? Color.appBlue.opacity(0.06) : Color.clear)

                        if city.key != cities.last?.key {
                            Divider().background(Color.appBorder).padding(.leading, 12)
                        }
                    }
                }
                .background(Color.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        )
    }

    private var residencyToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("I am a resident of this state/city")
                    .font(AppFont.body(14))
                    .foregroundColor(.textPrimary)
                Text("Affects resident vs non-resident tax rates for certain cities")
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
            }
            Spacer()
            Toggle("", isOn: $isResident)
                .tint(.appBlue)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Step 4: Disclaimer

    private var step4Disclaimer: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.appGold)
                Text("IMPORTANT NOTICE")
                    .font(AppFont.mono(12, weight: .bold))
                    .foregroundColor(.appGold)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(TaxDisclaimer.tier3)
                    .font(AppFont.body(13))
                    .foregroundColor(.textSub)
                    .lineSpacing(4)
                    .padding(16)
            }
            .background(Color.appGold.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.appGold.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            profileSummaryCard

            Button {
                disclaimerAcknowledged.toggle()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(disclaimerAcknowledged ? Color.appBlue : Color.appBorder, lineWidth: 2)
                            .frame(width: 22, height: 22)
                        if disclaimerAcknowledged {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.appBlue)
                        }
                    }
                    Text("I understand these are estimates only and not tax advice.")
                        .font(AppFont.body(13))
                        .foregroundColor(.textPrimary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var profileSummaryCard: some View {
        let income = Decimal(string: incomeText) ?? 70_000
        let incomeInt = NSDecimalNumber(decimal: income).intValue
        let incomeStr = incomeInt >= 1000 ? "$\(incomeInt / 1000)k" : "$\(incomeInt)"
        let stateName = TaxRatesLoader.stateName(for: selectedState) ?? selectedState

        return VStack(alignment: .leading, spacing: 10) {
            Text("YOUR TAX PROFILE")
                .font(AppFont.mono(10, weight: .semibold))
                .foregroundColor(.textMuted)

            HStack {
                profileSummaryRow(icon: "person.fill",
                                  label: "Filing Status",
                                  value: filingStatus.displayName)
            }
            Divider().background(Color.appBorder)
            profileSummaryRow(icon: "dollarsign.circle.fill",
                              label: "Ordinary Income",
                              value: incomeStr)
            Divider().background(Color.appBorder)
            profileSummaryRow(icon: "map.fill",
                              label: "State",
                              value: selectedState.isEmpty ? "Not set" : stateName)
            if !selectedCity.isEmpty {
                Divider().background(Color.appBorder)
                profileSummaryRow(icon: "building.2.fill",
                                  label: "City",
                                  value: TaxRatesLoader.load().cities[selectedCity]?.name ?? selectedCity)
            }
        }
        .padding(14)
        .background(Color.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.appBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func profileSummaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.appBlue)
                .frame(width: 20)
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(13, weight: .semibold))
                .foregroundColor(.textPrimary)
        }
    }

    // MARK: - Bottom nav bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.appBorder)
            HStack(spacing: 12) {
                if step > 1 {
                    Button {
                        withAnimation { step -= 1 }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                        }
                        .font(AppFont.body(15))
                        .foregroundColor(.textSub)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                nextButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var nextButton: some View {
        Button {
            handleNext()
        } label: {
            HStack(spacing: 6) {
                Text(step < totalSteps ? "Next" : step == totalSteps ? "Review" : "Save Profile")
                if step < 4 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .font(AppFont.body(15, weight: .semibold))
            .foregroundColor(nextEnabled ? .white : .textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(nextEnabled ? Color.appBlue : Color.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(nextEnabled ? Color.clear : Color.appBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!nextEnabled)
    }

    private var nextEnabled: Bool {
        switch step {
        case 1: return true
        case 2: return (Decimal(string: incomeText) ?? 0) > 0
        case 3: return !selectedState.isEmpty
        case 4: return disclaimerAcknowledged
        default: return false
        }
    }

    // MARK: - Navigation

    private func handleNext() {
        if step < totalSteps {
            withAnimation { step += 1 }
        } else if step == totalSteps {
            withAnimation { step = 4 }
        } else {
            // Save
            let income = Decimal(string: incomeText) ?? 70_000
            let profile = TaxProfile(
                filingStatus: filingStatus,
                ordinaryIncome: income,
                state: selectedState.isEmpty ? nil : selectedState,
                city: selectedCity.isEmpty  ? nil : selectedCity,
                isResident: isResident
            )
            taxProfileManager.save(profile)
            dismiss()
        }
    }
}

// MARK: - TaxDisclaimer constants

enum TaxDisclaimer {
    static let tier1 = "Estimated only · Not tax advice"

    static let tier2 = "Tax figures are estimates based on your profile. Actual liability may differ. Not tax advice."

    static let tier3 = "All tax calculations are estimates only, based on the cost basis and tax profile information you have entered. They do not constitute tax advice and may differ from your actual tax liability. Figures do not account for AMT, carry-forward losses, state-specific deductions, or wash sale adjustments. Consult a qualified tax professional before making investment decisions based on these estimates."

    static let lotsTier1 = "Tax lot figures are estimates only based on your entered cost basis. Verify all lot details with your broker or custodian. Long-Term status requires holding more than 366 days (IRS rule). Not tax advice · Consult a qualified tax professional."
}
