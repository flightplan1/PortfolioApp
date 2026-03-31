import SwiftUI
import CoreData

struct AddHoldingView: View {

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultBankFee") private var defaultBankFee: Double = 0

    // MARK: - Form State

    @State private var symbol: String = ""
    @State private var name: String = ""
    @State private var assetType: AssetType = .stock
    @State private var sector: String = ""
    @State private var isDRIPEnabled: Bool = false

    // Buy transaction
    @State private var quantity: String = ""
    @State private var pricePerShare: String = ""
    @State private var fee: String = ""
    @State private var tradeDate: Date = Date()
    @State private var lotMethod: LotMethod = .fifo

    // Date picker expand state
    @State private var showTradeDatePicker = false
    @State private var showExpiryDatePicker = false

    // Options-specific
    @State private var strikePrice: String = ""
    @State private var underlyingPriceAtExecution: String = ""
    @State private var expiryDate: Date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var optionType: OptionType = .call
    @State private var isShortPosition: Bool = false

    // Treasury-specific
    @State private var treasuryType: TreasuryInstrument = .tBill
    @State private var treasuryMaturityDate: Date = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var showTreasuryMaturityPicker = false
    @State private var cusip: String = ""

    // MARK: - Symbol Lookup

    @State private var isLookingUp = false

    // MARK: - Validation

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var isSaving = false

    // Cash deduction
    @State private var availableCash: Decimal = 0
    @State private var deductFromCash: Bool = false

    private var purchaseCost: Decimal? {
        guard let qty = Decimal.from(quantity), qty > 0,
              let price = Decimal.from(pricePerShare), price >= 0 else { return nil }
        let feeDecimal = Decimal.from(fee) ?? 0
        let multiplier: Decimal = assetType == .options ? 100 : 1
        return (qty * price * multiplier + feeDecimal).rounded(to: 2)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 16) {
                        identitySection
                        buyTransactionSection
                        lotMethodSection
                        if assetType != .cash && availableCash > 0 {
                            cashDeductionCard
                        }
                        saveButton
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSub)
                }
            }
            .alert("Check Your Inputs", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .task(id: symbol + assetType.rawValue) {
                guard !symbol.isEmpty, assetType == .stock || assetType == .etf else { return }
                try? await Task.sleep(nanoseconds: 600_000_000) // 600ms debounce
                guard !Task.isCancelled else { return }
                await lookupSymbolProfile()
            }
            .onAppear {
                availableCash = CashLedgerService.availableBalance(in: context)
                deductFromCash = availableCash > 0
            }
        }
    }

    // MARK: - Cash Deduction Card

    private var cashDeductionCard: some View {
        FormCard(title: "CASH BALANCE") {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deduct from Cash")
                            .font(AppFont.body(14))
                            .foregroundColor(.textPrimary)
                        if let cost = purchaseCost {
                            Text("Purchase cost: \(cost.asCurrency)")
                                .font(AppFont.mono(11))
                                .foregroundColor(.textMuted)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $deductFromCash)
                        .tint(.appGreen)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider().background(Color.appBorder)

                HStack {
                    Text("Available Cash")
                        .font(AppFont.body(13))
                        .foregroundColor(.textSub)
                    Spacer()
                    Text(availableCash.asCurrency)
                        .font(AppFont.mono(13, weight: .semibold))
                        .foregroundColor(availableCash > 0 ? .appGreen : .textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        FormCard(title: "POSITION") {
            VStack(spacing: 12) {
                // Asset Type Picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Asset Type")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.textMuted)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AssetType.allCases.filter { $0 != .cash }, id: \.self) { type in
                                FilterChip(
                                    label: type.displayName,
                                    isSelected: assetType == type
                                ) {
                                    assetType = type
                                    if type == .treasury {
                                        symbol = treasuryType.autoSymbol(maturity: treasuryMaturityDate)
                                        name   = treasuryType.autoName(maturity: treasuryMaturityDate)
                                    } else {
                                        symbol = ""
                                        name   = ""
                                    }
                                    sector = ""
                                }
                            }
                        }
                    }
                }

                Divider().background(Color.appBorder)

                if assetType == .treasury {
                    // Treasury Type
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instrument")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TreasuryInstrument.allCases, id: \.self) { t in
                                    FilterChip(label: t.shortLabel, isSelected: treasuryType == t) {
                                        treasuryType = t
                                        symbol = t.autoSymbol(maturity: treasuryMaturityDate)
                                        name = t.autoName(maturity: treasuryMaturityDate)
                                    }
                                }
                            }
                        }
                    }

                    Divider().background(Color.appBorder)

                    // Maturity Date
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Maturity Date")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textMuted)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showTreasuryMaturityPicker.toggle() }
                        } label: {
                            HStack {
                                Text(treasuryMaturityDate.formatted(.dateTime.month(.abbreviated).day().year()))
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundColor(.textPrimary)
                                Spacer()
                                Image(systemName: showTreasuryMaturityPicker ? "chevron.up" : "calendar")
                                    .font(.system(size: 12))
                                    .foregroundColor(.appBlue)
                            }
                        }
                        .buttonStyle(.plain)
                        .onChange(of: treasuryMaturityDate) { _, newDate in
                            symbol = treasuryType.autoSymbol(maturity: newDate)
                            name   = treasuryType.autoName(maturity: newDate)
                            withAnimation(.easeInOut(duration: 0.2)) { showTreasuryMaturityPicker = false }
                        }
                        if showTreasuryMaturityPicker {
                            DatePicker("", selection: $treasuryMaturityDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .tint(.appBlue)
                                .colorScheme(.dark)
                                .padding(.top, 4)
                        }
                    }

                    Divider().background(Color.appBorder)

                    // Symbol (auto-generated, editable)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Symbol (auto-generated)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textMuted)
                        TextField(treasuryType.autoSymbol(maturity: treasuryMaturityDate), text: $symbol)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.textPrimary)
                            .tint(.appBlue)
                            .onChange(of: symbol) { _, v in symbol = v.uppercased() }
                    }

                    Divider().background(Color.appBorder)

                    // Name (auto-generated, editable)
                    FormField(label: "Name (auto-generated)", placeholder: treasuryType.autoName(maturity: treasuryMaturityDate)) {
                        TextField(treasuryType.autoName(maturity: treasuryMaturityDate), text: $name)
                    }

                    Divider().background(Color.appBorder)

                    // CUSIP (optional)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CUSIP (optional)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.textMuted)
                        TextField("e.g. 912796YG7", text: $cusip)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.textPrimary)
                            .tint(.appBlue)
                            .onChange(of: cusip) { _, v in cusip = v.uppercased() }
                    }

                } else {
                    // Non-treasury: standard Symbol field
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Symbol")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.textMuted)
                            if isLookingUp {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                        }
                        TextField("NVDA", text: $symbol)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.textPrimary)
                            .tint(.appBlue)
                            .onChange(of: symbol) { _, newValue in
                                symbol = newValue.uppercased()
                                name = ""
                                sector = ""
                                if assetType == .options, !newValue.isEmpty {
                                    name = "\(newValue.uppercased()) \(optionType.displayName)"
                                }
                            }
                    }

                    Divider().background(Color.appBorder)

                    // Name — editable for non-options only; options name is auto-generated silently
                    if assetType != .options {
                        FormField(label: "Name", placeholder: "NVIDIA Corporation") {
                            TextField("NVIDIA Corporation", text: $name)
                        }
                    }

                    // Sector — stocks only
                    if assetType == .stock {
                        Divider().background(Color.appBorder)
                        FormField(label: "Sector (optional)", placeholder: "Semiconductors") {
                            TextField("Semiconductors", text: $sector)
                        }
                    }

                    if assetType == .options {
                        Divider().background(Color.appBorder)
                        Toggle(isOn: $isShortPosition) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isShortPosition ? "Sell to Open (STO)" : "Buy to Open (BTO)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.textPrimary)
                                Text(isShortPosition
                                     ? "Writing/selling the option — collecting premium"
                                     : "Purchasing the option — paying premium")
                                    .font(.system(size: 11))
                                    .foregroundColor(.textSub)
                            }
                        }
                        .tint(.appPurple)
                    }

                    if assetType != .options && assetType != .crypto {
                        Divider().background(Color.appBorder)
                        Toggle(isOn: $isDRIPEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DRIP")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.textPrimary)
                                Text("Auto-reinvest dividends")
                                    .font(.system(size: 11))
                                    .foregroundColor(.textSub)
                            }
                        }
                        .tint(.appGreen)
                    }
                }
            }
        }
    }

    // MARK: - Buy Transaction Section

    private var buyTransactionSection: some View {
        FormCard(title: assetType == .options ? (isShortPosition ? "SELL TO OPEN" : "BUY TO OPEN") : "OPENING TRANSACTION") {
            VStack(spacing: 12) {
                // Call / Put — options only, shown first
                if assetType == .options {
                    HStack(spacing: 8) {
                        ForEach(OptionType.allCases, id: \.self) { type in
                            Button {
                                optionType = type
                                if !symbol.isEmpty {
                                    name = "\(symbol) \(type.displayName)"
                                }
                            } label: {
                                Text(type.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(optionType == type ? .white : .textSub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(optionType == type ? (type == .call ? Color.appGreen : Color.appRed) : Color.surfaceAlt)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider().background(Color.appBorder)
                }

                // Trade Date
                datePickerRow(label: "Trade Date", date: $tradeDate, isExpanded: $showTradeDatePicker)

                Divider().background(Color.appBorder)

                // Contracts + Premium (or Quantity + Price for non-options)
                HStack(spacing: 12) {
                    FormField(
                        label: assetType == .options ? "Contracts" : assetType == .treasury ? "Face Value ($)" : "Quantity",
                        placeholder: assetType == .treasury ? "1000" : "100"
                    ) {
                        TextField(assetType == .treasury ? "1000" : "100", text: $quantity)
                            .keyboardType(.decimalPad)
                    }
                    FormField(
                        label: assetType == .options ? "Premium / Share" : assetType == .treasury ? "Purchase Price ($)" : "Price / Share",
                        placeholder: assetType == .treasury ? "980.00" : "875.00"
                    ) {
                        TextField(assetType == .treasury ? "980.00" : "875.00", text: $pricePerShare)
                            .keyboardType(.decimalPad)
                    }
                }

                // Strike Price + Stock Price at Execution — directly below contracts/premium
                if assetType == .options {
                    Divider().background(Color.appBorder)

                    HStack(spacing: 12) {
                        FormField(label: "Strike Price", placeholder: "500.00") {
                            TextField("500.00", text: $strikePrice)
                                .keyboardType(.decimalPad)
                        }
                        FormField(label: "Stock Price", placeholder: "490.00") {
                            TextField("490.00", text: $underlyingPriceAtExecution)
                                .keyboardType(.decimalPad)
                        }
                    }

                    if let distancePct = strikeDistancePercent {
                        HStack(spacing: 4) {
                            Image(systemName: distancePct >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10))
                            Text("\(abs(distancePct), specifier: "%.2f")% \(distancePct >= 0 ? "above" : "below") stock price")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        .foregroundColor(distancePct >= 0 ? .appGreen : .appRed)
                        .padding(.top, 2)
                    }

                    Divider().background(Color.appBorder)

                    datePickerRow(label: "Expiry Date", date: $expiryDate, isExpanded: $showExpiryDatePicker)

                    Divider().background(Color.appBorder)

                    FormField(label: "Fee / Commission", placeholder: "0.00") {
                        TextField("0.00", text: $fee)
                            .keyboardType(.decimalPad)
                    }
                }

                // Position size hint (options)
                if assetType == .options, let contracts = Int(quantity) {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.textMuted)
                        Text(OptionsCalculator.positionSizeDescription(contracts: contracts))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.textMuted)
                    }
                    .padding(.top, 4)
                }

                // Cost basis preview
                if let costBasis = totalCostBasis {
                    HStack {
                        Text("Total cost basis")
                            .font(.system(size: 12))
                            .foregroundColor(.textSub)
                        Spacer()
                        Text(costBasis.rounded(to: 2).asCurrency)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPrimary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Lot Method Section

    private var lotMethodSection: some View {
        FormCard(title: "DEFAULT LOT METHOD") {
            Picker("Lot Method", selection: $lotMethod) {
                ForEach(LotMethod.allCases, id: \.self) { method in
                    Text(method.shortName).tag(method)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            save()
        } label: {
            Group {
                if isSaving {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Add Holding")
                        .font(.system(size: 16, weight: .semibold))
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

    // MARK: - Validation

    // MARK: - Symbol Lookup

    @MainActor
    private func lookupSymbolProfile() async {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return }

        isLookingUp = true
        defer { isLookingUp = false }

        // Step 1: try profile2 (works for stocks, not ETFs)
        await fetchProfile2(symbol: symbol, apiKey: apiKey)

        // Step 2: if name still empty, fall back to symbol search
        if name.isEmpty {
            await fetchSymbolSearch(symbol: symbol, apiKey: apiKey)
        }
    }

    private func fetchProfile2(symbol: String, apiKey: String) async {
        var components = URLComponents(string: "https://finnhub.io/api/v1/stock/profile2")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            let profile = try JSONDecoder().decode(FinnhubProfile.self, from: data)
            if let fetchedName = profile.name, !fetchedName.isEmpty {
                name = fetchedName
            }
            if let industry = profile.finnhubIndustry, !industry.isEmpty {
                sector = industry
            }
        } catch { }
    }

    private func fetchSymbolSearch(symbol: String, apiKey: String) async {
        var components = URLComponents(string: "https://finnhub.io/api/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            let result = try JSONDecoder().decode(FinnhubSearchResponse.self, from: data)
            // Find exact symbol match (case-insensitive)
            if let match = result.result?.first(where: {
                $0.displaySymbol.uppercased() == symbol.uppercased()
            }), !match.description.isEmpty {
                name = match.description.capitalized
            }
        } catch { }
    }

    @ViewBuilder
    private func datePickerRow(label: String, date: Binding<Date>, isExpanded: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Text(date.wrappedValue.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.textPrimary)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "calendar")
                        .font(.system(size: 12))
                        .foregroundColor(.appBlue)
                }
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue {
                DatePicker("", selection: date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(.appBlue)
                    .colorScheme(.dark)
                    .padding(.top, 4)
                    .onChange(of: date.wrappedValue) { _, _ in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.wrappedValue = false
                        }
                    }
            }
        }
    }

    private var strikeDistancePercent: Double? {
        guard let strike = Double(strikePrice), strike > 0,
              let underlying = Double(underlyingPriceAtExecution), underlying > 0 else { return nil }
        return ((strike - underlying) / underlying) * 100
    }

    private var totalCostBasis: Decimal? {
        guard let qty = Decimal.from(quantity), let price = Decimal.from(pricePerShare),
              qty > 0, price > 0 else { return nil }
        let feeDecimal = Decimal.from(fee) ?? 0
        if assetType == .options, let contracts = Int(quantity) {
            return OptionsCalculator.totalCost(contracts: contracts, premiumPerShare: price, fee: feeDecimal)
        }
        return qty * price + feeDecimal
    }

    private var canSave: Bool {
        let nameOK = assetType == .options ? !symbol.isEmpty : !name.isEmpty
        return !symbol.isEmpty && nameOK &&
            Decimal.from(quantity) != nil && Decimal.from(pricePerShare) != nil
    }

    private func validate() -> String? {
        if symbol.isEmpty { return "Symbol is required." }
        if assetType != .options && name.isEmpty { return "Name is required." }
        guard let qty = Decimal.from(quantity), qty > 0 else { return "Quantity must be greater than zero." }
        guard let price = Decimal.from(pricePerShare), price >= 0 else { return "Price cannot be negative." }
        if assetType == .options, let contracts = Int(quantity), contracts <= 0 {
            return "Number of contracts must be greater than zero."
        }
        return nil
    }

    // MARK: - Save

    private func save() {
        // Ensure options always have a name
        if assetType == .options && name.isEmpty {
            name = "\(symbol) \(optionType.displayName)"
        }

        if let error = validate() {
            validationMessage = error
            showValidationError = true
            return
        }

        isSaving = true

        let qty = Decimal.from(quantity)!
        let price = Decimal.from(pricePerShare)!
        let feeDecimal = Decimal.from(fee) ?? 0

        // Reuse existing holding for same symbol + asset type, or create a new one
        let existingRequest = Holding.fetchRequest()
        existingRequest.predicate = NSPredicate(
            format: "symbol == %@ AND assetTypeRaw == %@",
            symbol.uppercased(), assetType.rawValue
        )
        existingRequest.fetchLimit = 1
        let existingHolding = (try? context.fetch(existingRequest))?.first

        let holding: Holding
        if let existing = existingHolding {
            holding = existing
            // Update mutable fields if provided
            if !name.isEmpty { holding.name = name }
            if !sector.isEmpty { holding.sector = sector }
        } else {
            holding = Holding(context: context)
            holding.symbol = symbol.uppercased()
            holding.name = name
            holding.assetType = assetType
            holding.sector = sector.isEmpty ? nil : sector
            holding.isDRIPEnabled = isDRIPEnabled
            holding.currency = "USD"
        }

        if assetType == .options {
            holding.optionType = optionType
            holding.expiryDate = expiryDate
            holding.strikePrice = Decimal.from(strikePrice)
            holding.underlyingPriceAtExecution = Decimal.from(underlyingPriceAtExecution)
            holding.isShortPosition = isShortPosition
        }

        if assetType == .treasury {
            holding.expiryDate = treasuryMaturityDate
            if !cusip.isEmpty {
                holding.notes = "CUSIP: \(cusip)"
            }
        }

        // Determine actual quantity for options
        let lotQty: Decimal
        if assetType == .options, let contracts = Int(quantity) {
            lotQty = Decimal(contracts)
        } else {
            lotQty = qty
        }

        // Next lot number for this holding
        let lotsRequest = Lot.openLots(for: holding.id)
        let existingLots = (try? context.fetch(lotsRequest)) ?? []
        let nextLotNumber = (existingLots.map { $0.lotNumber }.max() ?? 0) + 1

        // Create Lot — options lots use ×100 multiplier so totalCostBasis = contracts × premium × 100 + fee
        let lot = Lot.create(
            in: context,
            holdingId: holding.id,
            lotNumber: nextLotNumber,
            quantity: lotQty,
            costBasisPerShare: price,
            purchaseDate: tradeDate,
            fee: feeDecimal,
            source: .manual,
            contractMultiplier: assetType == .options ? 100 : 1
        )

        // Create Transaction
        let transaction = Transaction.createBuy(
            in: context,
            holdingId: holding.id,
            lotId: lot.id,
            quantity: lotQty,
            pricePerShare: price,
            fee: feeDecimal,
            tradeDate: tradeDate,
            lotMethod: lotMethod
        )

        do {
            try context.save()
            // Deduct purchase cost from Cash if toggled on (skip for Cash holding itself)
            if deductFromCash && assetType != .cash, let cost = purchaseCost {
                CashLedgerService.debit(amount: cost, in: context)
                try? context.save()
            }
            // Schedule expiry notifications for new options holdings
            if assetType == .options {
                Task { await OptionsNotificationManager.shared.scheduleExpiryNotifications(for: holding) }
            }
            dismiss()
        } catch {
            validationMessage = "Failed to save: \(error.localizedDescription)"
            showValidationError = true
            context.rollback()
        }

        isSaving = false
        _ = transaction // suppress unused warning
    }
}

// MARK: - Form Components

struct FormCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(14)
            .cardStyle()
        }
    }
}

struct FormField<Content: View>: View {
    let label: String
    let placeholder: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted)
            content
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.textPrimary)
                .tint(.appBlue)
        }
    }
}

// MARK: - Treasury Instrument

enum TreasuryInstrument: String, CaseIterable {
    case tBill   = "tBill"
    case tNote   = "tNote"
    case tBond   = "tBond"
    case tips    = "tips"
    case iBond   = "iBond"

    var shortLabel: String {
        switch self {
        case .tBill:  return "T-Bill"
        case .tNote:  return "T-Note"
        case .tBond:  return "T-Bond"
        case .tips:   return "TIPS"
        case .iBond:  return "I-Bond"
        }
    }

    func autoSymbol(maturity: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMM"
        let suffix = formatter.string(from: maturity)
        switch self {
        case .tBill:  return "TBILL-\(suffix)"
        case .tNote:  return "TNOTE-\(suffix)"
        case .tBond:  return "TBOND-\(suffix)"
        case .tips:   return "TIPS-\(suffix)"
        case .iBond:  return "IBOND-\(suffix)"
        }
    }

    func autoName(maturity: Date) -> String {
        let monthYear = maturity.formatted(.dateTime.month(.abbreviated).year())
        switch self {
        case .tBill:  return "T-Bill — Matures \(monthYear)"
        case .tNote:  return "T-Note — Matures \(monthYear)"
        case .tBond:  return "T-Bond — Matures \(monthYear)"
        case .tips:   return "TIPS — Matures \(monthYear)"
        case .iBond:  return "I-Bond — Matures \(monthYear)"
        }
    }
}

// MARK: - Finnhub Profile Model

private struct FinnhubProfile: Decodable {
    let name: String?
    let finnhubIndustry: String?
}

private struct FinnhubSearchResponse: Decodable {
    let result: [FinnhubSearchItem]?
}

private struct FinnhubSearchItem: Decodable {
    let description: String
    let displaySymbol: String
}

// MARK: - Preview

#Preview {
    AddHoldingView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
