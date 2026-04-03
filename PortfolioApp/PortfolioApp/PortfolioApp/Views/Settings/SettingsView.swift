import SwiftUI
import CoreData

struct SettingsView: View {

    @EnvironmentObject private var lockManager:            AppLockManager
    @EnvironmentObject private var taxProfileManager:      TaxProfileManager
    @EnvironmentObject private var remoteTaxRatesService:  RemoteTaxRatesService
    @ObservedObject private var notifPrefs = NotificationPreferencesManager.shared

    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        fetchRequest: Holding.allActiveRequest(),
        animation: .none
    ) private var holdings: FetchedResults<Holding>

    @State private var showTaxOnboarding  = false
    @State private var remoteURLDraft     = ""
    @State private var showURLSaveConfirm = false

    // MARK: - Finnhub Key State

    @State private var finnhubKeyInput: String = ""
    @State private var showFinnhubKey: Bool = false
    @State private var keyStatus: FinnhubKeyStatus = .unchecked
    @State private var keyError: String?
    @State private var isTesting: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showImport = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    taxProfileSection
                    taxRatesDataSection
                    apiKeysSection
                    notificationsSection
                    securitySection
                    dataSyncSection
                    aboutSection
                }
                .padding(16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadExistingKey()
            remoteURLDraft = remoteTaxRatesService.remoteURL
        }
        .sheet(isPresented: $showTaxOnboarding) {
            OnboardingView()
                .environmentObject(taxProfileManager)
        }
        .sheet(isPresented: $showImport) {
            ImportFlowView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
    }

    // MARK: - Tax Profile Section

    private var taxProfileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TAX PROFILE")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // Status row
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(taxProfileManager.isProfileComplete ? Color.appGreenDim : Color.appGoldDim)
                            .frame(width: 32, height: 32)
                        Image(systemName: taxProfileManager.isProfileComplete
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(taxProfileManager.isProfileComplete ? .appGreen : .appGold)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(taxProfileManager.isProfileComplete ? "Profile complete" : "Profile incomplete")
                            .font(AppFont.body(14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text(taxProfileManager.isProfileComplete
                             ? taxProfileManager.profile.shortLabel
                             : "Using Single filer, $70k income defaults")
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                // Profile details (if complete)
                if taxProfileManager.isProfileComplete {
                    let p = taxProfileManager.profile
                    settingsRow(label: "Filing Status", value: p.filingStatus.displayName)
                    settingsRow(label: "Annual Income",
                                value: "$\(NSDecimalNumber(decimal: p.ordinaryIncome).intValue / 1000)k")
                    if let stateCode = p.state,
                       let stateName = TaxRatesLoader.stateName(for: stateCode) {
                        settingsRow(label: "State", value: "\(stateCode) — \(stateName)")
                    }
                    if let cityKey = p.city,
                       let cityName = TaxRatesLoader.load().cities[cityKey]?.name {
                        settingsRow(label: "City", value: cityName)
                    }
                    settingsRow(label: "Residency", value: p.isResident ? "Resident" : "Non-Resident")

                    Divider().background(Color.appBorder)
                }

                // Edit button
                Button {
                    showTaxOnboarding = true
                } label: {
                    HStack {
                        Text(taxProfileManager.isProfileComplete ? "Edit Tax Profile" : "Set Up Tax Profile")
                            .font(AppFont.body(14, weight: .medium))
                            .foregroundColor(.appBlue)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .cardStyle()

            // Tier 1 disclaimer footer
            Text(TaxDisclaimer.tier1)
                .font(AppFont.body(11))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 4)
        }
    }

    private func settingsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(AppFont.body(13))
                .foregroundColor(.textSub)
            Spacer()
            Text(value)
                .font(AppFont.mono(12, weight: .medium))
                .foregroundColor(.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Tax Rates Data Section

    private var taxRatesDataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TAX RATES DATA")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {

                // Source status row
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(remoteTaxRatesService.isOutdated ? Color.appRedDim : Color.appGreenDim)
                            .frame(width: 32, height: 32)
                        Image(systemName: remoteTaxRatesService.isOutdated
                              ? "calendar.badge.exclamationmark" : "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(remoteTaxRatesService.isOutdated ? .appRed : .appGreen)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(remoteTaxRatesService.ratesSource.label)
                            .font(AppFont.body(13, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        if remoteTaxRatesService.isOutdated {
                            Text("Rates are from a prior tax year")
                                .font(AppFont.body(11))
                                .foregroundColor(.appRed)
                        } else {
                            Text("Rates are current for \(remoteTaxRatesService.activeRates.effectiveYear)")
                                .font(AppFont.body(11))
                                .foregroundColor(.appGreen)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                // Last fetched row
                if let lastFetch = remoteTaxRatesService.lastFetchDate {
                    Divider().background(Color.appBorder)
                    settingsRow(label: "Last Updated",
                                value: lastFetch.formatted(date: .abbreviated, time: .omitted))
                }

                // Remote URL input
                Divider().background(Color.appBorder)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                        Text("REMOTE URL (OPTIONAL)")
                            .font(AppFont.mono(10, weight: .bold))
                            .foregroundColor(.textMuted)
                            .kerning(0.5)
                    }

                    HStack(spacing: 8) {
                        TextField("https://example.com/tax-rates.json", text: $remoteURLDraft)
                            .font(AppFont.mono(12))
                            .foregroundColor(.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)

                        if !remoteURLDraft.isEmpty {
                            Button {
                                remoteURLDraft = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.textMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.surfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Point to a JSON file in the tax-rates.json format. Leave blank to use bundled rates.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Error row
                if let error = remoteTaxRatesService.lastFetchError {
                    Divider().background(Color.appBorder)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.appRed)
                        Text(error)
                            .font(AppFont.body(12))
                            .foregroundColor(.appRed)
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Divider().background(Color.appBorder)

                // Action buttons
                HStack(spacing: 12) {
                    // Save URL
                    Button {
                        remoteTaxRatesService.saveRemoteURL(remoteURLDraft)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Save URL")
                                .font(AppFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(remoteURLDraft != remoteTaxRatesService.remoteURL
                                         ? .appBg : .textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(remoteURLDraft != remoteTaxRatesService.remoteURL
                                    ? Color.appGreen : Color.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(remoteURLDraft == remoteTaxRatesService.remoteURL)

                    // Fetch now
                    Button {
                        Task { await remoteTaxRatesService.fetch() }
                    } label: {
                        HStack(spacing: 6) {
                            if remoteTaxRatesService.isFetching {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .appBlue))
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(remoteTaxRatesService.isFetching ? "Fetching..." : "Fetch Now")
                                .font(AppFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(.appBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.appBlueDim)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(remoteTaxRatesService.remoteURL.isEmpty || remoteTaxRatesService.isFetching)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .cardStyle()

            // Offline fallback note
            if remoteTaxRatesService.ratesSource.isOffline {
                HStack(spacing: 4) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10))
                        .foregroundColor(.textMuted)
                    Text("Using v\(remoteTaxRatesService.activeRates.version) bundled rates (offline). Set a remote URL above to enable automatic updates.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API KEYS")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // Finnhub header row
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.appBlue)
                        .frame(width: 28, height: 28)
                        .background(Color.appBlueDim)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finnhub")
                            .font(AppFont.body(14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("Stocks, ETFs, options, earnings, news")
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                    }

                    Spacer()

                    keyStatusBadge
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().background(Color.appBorder)

                // Key input row
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.textMuted)
                        .frame(width: 20)

                    Group {
                        if showFinnhubKey {
                            TextField("Paste API key...", text: $finnhubKeyInput)
                        } else {
                            SecureField("Paste API key...", text: $finnhubKeyInput)
                        }
                    }
                    .font(AppFont.mono(13))
                    .foregroundColor(.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: finnhubKeyInput) { keyStatus = .unchecked }

                    Button {
                        showFinnhubKey.toggle()
                    } label: {
                        Image(systemName: showFinnhubKey ? "eye.slash" : "eye")
                            .font(.system(size: 14))
                            .foregroundColor(.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let error = keyError {
                    Divider().background(Color.appBorder)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.appRed)
                        Text(error)
                            .font(AppFont.body(12))
                            .foregroundColor(.appRed)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Divider().background(Color.appBorder)

                // Action buttons
                HStack(spacing: 12) {
                    // Test
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .appBlue))
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "wifi")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(isTesting ? "Testing..." : "Test")
                                .font(AppFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(.appBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.appBlueDim)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(finnhubKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)

                    // Save
                    Button(action: saveKey) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Save")
                                .font(AppFont.body(13, weight: .semibold))
                        }
                        .foregroundColor(canSaveKey ? .appBg : .textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(canSaveKey ? Color.appGreen : Color.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!canSaveKey)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                // Delete existing key
                if APIKeyManager.hasFinnhubKey {
                    Divider().background(Color.appBorder)
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text("Remove saved key")
                                .font(AppFont.body(12))
                        }
                        .foregroundColor(.appRed)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .confirmationDialog("Remove API Key", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Remove Key", role: .destructive) { deleteKey() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Price updates will stop working until you add a new key.")
                    }
                }
            }
            .cardStyle()

            // Footnote
            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundColor(.textMuted)
                Text("Stored in iOS Keychain. Never sent to any server other than Finnhub.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOTIFICATIONS")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                notifToggleRow(
                    icon: "calendar.badge.clock",
                    iconColor: .appBlue,
                    title: "Earnings Alerts",
                    subtitle: "Day before a held stock reports earnings",
                    isOn: $notifPrefs.earningsAlertsEnabled
                )
                Divider().background(Color.appBorder)
                notifToggleRow(
                    icon: "chart.line.uptrend.xyaxis",
                    iconColor: .appGold,
                    title: "Long-Term Tax Alerts",
                    subtitle: "Day before a lot qualifies for long-term rates",
                    isOn: $notifPrefs.ltThresholdAlertsEnabled
                )
                Divider().background(Color.appBorder)
                notifToggleRow(
                    icon: "newspaper.fill",
                    iconColor: .appGreen,
                    title: "Breaking News",
                    subtitle: "Up to 3 alerts per day for new articles",
                    isOn: $notifPrefs.breakingNewsAlertsEnabled
                )
            }
            .cardStyle()

            // Per-symbol mutes
            let stockSymbols = holdings
                .filter { $0.assetType == .stock || $0.assetType == .etf || $0.assetType == .crypto }
                .map { $0.symbol }
                .sorted()

            if !stockSymbols.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MUTED SYMBOLS")
                        .sectionTitleStyle()
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(stockSymbols.enumerated()), id: \.element) { index, symbol in
                            HStack {
                                Text(symbol)
                                    .font(AppFont.mono(13, weight: .semibold))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { !notifPrefs.isMuted(symbol) },
                                    set: { enabled in
                                        if !enabled { notifPrefs.toggleMute(symbol) }
                                        else if notifPrefs.isMuted(symbol) { notifPrefs.toggleMute(symbol) }
                                    }
                                ))
                                .labelsHidden()
                                .tint(.appGreen)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            if index < stockSymbols.count - 1 {
                                Divider().background(Color.appBorder)
                            }
                        }
                    }
                    .cardStyle()

                    Text("Muting a symbol silences all notifications for that holding.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private func notifToggleRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.body(14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.appGreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Security Section

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SECURITY")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // Biometric lock toggle
                HStack(spacing: 12) {
                    Image(systemName: lockManager.biometricType.systemImageName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.appGold)
                        .frame(width: 28, height: 28)
                        .background(Color.appGoldDim)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(lockManager.biometricType.displayName) Lock")
                            .font(AppFont.body(14, weight: .semibold))
                            .foregroundColor(.textPrimary)
                        Text("Require authentication on launch")
                            .font(AppFont.body(11))
                            .foregroundColor(.textMuted)
                    }

                    Spacer()

                    Toggle("", isOn: $lockManager.lockEnabled)
                        .labelsHidden()
                        .tint(.appGreen)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if lockManager.lockEnabled {
                    Divider().background(Color.appBorder)

                    // Lock delay picker
                    HStack(spacing: 12) {
                        Image(systemName: "timer")
                            .font(.system(size: 13))
                            .foregroundColor(.textMuted)
                            .frame(width: 28)

                        Text("Lock After")
                            .font(AppFont.body(14))
                            .foregroundColor(.textSub)

                        Spacer()

                        Picker("Lock After", selection: $lockManager.lockAfterSeconds) {
                            ForEach(AppLockManager.lockDelayOptions, id: \.seconds) { option in
                                Text(option.label)
                                    .font(AppFont.body(13))
                                    .tag(option.seconds)
                            }
                        }
                        .tint(.appBlue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .cardStyle()

            #if DEBUG
            HStack(spacing: 4) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.appGold)
                Text("Lock screen bypassed in DEBUG builds.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 4)
            #endif
        }
    }

    // MARK: - Data & Sync Section

    private var dataSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DATA & SYNC")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                iCloudRow
                Divider().background(Color.appBorder).padding(.horizontal, 16)
                importExportRow
            }
            .cardStyle()
        }
    }

    private var importExportRow: some View {
        Button {
            showImport = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.appBlue)
                    .frame(width: 28, height: 28)
                    .background(Color.appBlueDim)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Import / Export")
                        .font(AppFont.body(14, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text("Import CSV or JSON holdings, or export your data")
                        .font(AppFont.body(11))
                        .foregroundColor(.textSub)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var iCloudRow: some View {
        let available = PersistenceController.shared.isCloudKitAvailable
        return HStack(spacing: 12) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(available ? .appGreen : .textMuted)
                .frame(width: 28, height: 28)
                .background(available ? Color.appGreenDim : Color.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud Sync")
                    .font(AppFont.body(14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(available
                     ? "Active — syncing across your devices"
                     : "Unavailable — data is local only")
                    .font(AppFont.body(11))
                    .foregroundColor(available ? .appGreen : .textMuted)
            }

            Spacer()

            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(available ? .appGreen : .textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ABOUT")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // Version row
                HStack {
                    Text("Version")
                        .font(AppFont.body(14))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text(appVersion)
                        .font(AppFont.mono(13))
                        .foregroundColor(.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)

                // Price sources
                HStack(alignment: .top) {
                    Text("Price Sources")
                        .font(AppFont.body(14))
                        .foregroundColor(.textSub)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Finnhub — Stocks, ETFs, Options")
                            .font(AppFont.mono(11))
                            .foregroundColor(.textMuted)
                        Text("CoinGecko — Crypto")
                            .font(AppFont.mono(11))
                            .foregroundColor(.textMuted)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().background(Color.appBorder)

                // Disclaimer
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.appGold)
                        Text("DISCLAIMER")
                            .font(AppFont.mono(10, weight: .bold))
                            .foregroundColor(.appGold)
                            .kerning(0.8)
                    }
                    Text("This app is for informational purposes only and does not constitute financial, investment, or tax advice. All tax estimates are approximate (~) and based on simplified federal calculations. Consult a qualified tax professional for advice specific to your situation. Price data may be delayed.")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .cardStyle()
        }
    }

    // MARK: - Helpers

    private enum FinnhubKeyStatus {
        case unchecked, valid, invalid

        var color: Color {
            switch self {
            case .unchecked: return .textMuted
            case .valid:     return .appGreen
            case .invalid:   return .appRed
            }
        }

        var label: String {
            switch self {
            case .unchecked: return APIKeyManager.hasFinnhubKey ? "SAVED" : "NOT SET"
            case .valid:     return "VALID"
            case .invalid:   return "INVALID"
            }
        }
    }

    private var keyStatusBadge: some View {
        Text(keyStatus.label)
            .font(AppFont.mono(10, weight: .bold))
            .foregroundColor(keyStatus.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(keyStatus.color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var canSaveKey: Bool {
        let trimmed = finnhubKeyInput.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && keyStatus != .invalid
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Actions

    private func loadExistingKey() {
        if let key = try? APIKeyManager.getFinnhubKey(), !key.isEmpty {
            finnhubKeyInput = key
            keyStatus = .unchecked
        }
    }

    private func saveKey() {
        let trimmed = finnhubKeyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try APIKeyManager.saveFinnhubKey(trimmed)
            keyError = nil
            NotificationCenter.default.post(name: .finnhubKeyDidChange, object: nil)
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try APIKeyManager.deleteFinnhubKey()
            finnhubKeyInput = ""
            keyStatus = .unchecked
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func testConnection() {
        let trimmed = finnhubKeyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        isTesting = true
        keyError = nil

        // Hit the Finnhub /quote endpoint for AAPL as a lightweight connectivity test
        let urlString = "https://finnhub.io/api/v1/quote?symbol=AAPL&token=\(trimmed)"
        guard let url = URL(string: urlString) else {
            isTesting = false
            keyStatus = .invalid
            keyError = "Invalid URL"
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                isTesting = false

                if let error = error {
                    keyStatus = .invalid
                    keyError = "Connection failed: \(error.localizedDescription)"
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    keyStatus = .invalid
                    keyError = "Unexpected response"
                    return
                }

                switch http.statusCode {
                case 200:
                    // Verify the response has a non-nil 'c' (current price) field
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["c"] != nil {
                        keyStatus = .valid
                    } else {
                        keyStatus = .invalid
                        keyError = "Received unexpected data from Finnhub"
                    }
                case 401, 403:
                    keyStatus = .invalid
                    keyError = "Invalid API key — check your Finnhub dashboard"
                case 429:
                    keyStatus = .invalid
                    keyError = "Rate limited — try again in a moment"
                default:
                    keyStatus = .invalid
                    keyError = "Finnhub returned status \(http.statusCode)"
                }
            }
        }.resume()
    }
}

#Preview {
    NavigationView {
        SettingsView()
            .environmentObject(AppLockManager())
            .environmentObject(TaxProfileManager.shared)
            .environmentObject(RemoteTaxRatesService.shared)
    }
    .preferredColorScheme(.dark)
}
