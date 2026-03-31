import Foundation

// MARK: - Tax Estimate Result

struct TaxEstimate {
    let gain:         Decimal
    let isLongTerm:   Bool
    let isSection1256: Bool

    let federalTax:  Decimal
    let federalRate: Decimal   // effective % of gain
    let niit:        Decimal
    let stateTax:    Decimal
    let stateRate:   Decimal   // effective % of gain
    let cityTax:     Decimal
    let cityRate:    Decimal   // effective % of gain
    let totalTax:    Decimal
    let netProceeds: Decimal

    let washSaleWarning: Bool
    let amtWarning:      Bool

    var effectiveTotalRate: Decimal {
        gain > 0 ? (totalTax / gain * 100).rounded(to: 2) : 0
    }

    /// Returns true when any tax layer applies (estimate is meaningful to show).
    var hasTaxLiability: Bool { totalTax > 0 }

    /// A zero estimate for loss/zero-gain scenarios.
    static func zero(gain: Decimal, washSale: Bool = false) -> TaxEstimate {
        TaxEstimate(gain: gain, isLongTerm: false, isSection1256: false,
                    federalTax: 0, federalRate: 0, niit: 0,
                    stateTax: 0, stateRate: 0, cityTax: 0, cityRate: 0,
                    totalTax: 0, netProceeds: gain,
                    washSaleWarning: washSale, amtWarning: false)
    }
}

// MARK: - TaxEngine

struct TaxEngine {

    let rates:   TaxRates
    let profile: TaxProfile

    // MARK: - Main entry point

    func estimate(
        gain: Decimal,
        purchaseDate: Date,
        saleDate: Date,
        isSection1256: Bool = false,
        washSaleWarning: Bool = false
    ) -> TaxEstimate {
        guard gain > 0 else {
            return .zero(gain: gain, washSale: washSaleWarning)
        }

        let isLT    = isLongTerm(purchaseDate: purchaseDate, saleDate: saleDate)
        let income  = profile.ordinaryIncome
        let status  = profile.filingStatus

        // Federal
        let federalTax: Decimal
        if isSection1256 {
            let ltPortion = (gain * Decimal(string: "0.6")!).rounded(to: 6)
            let stPortion = (gain * Decimal(string: "0.4")!).rounded(to: 6)
            federalTax = ltcgTax(gain: ltPortion, income: income, status: status)
                       + stackedBracketTax(existingIncome: income, additionalIncome: stPortion, status: status)
        } else if isLT {
            federalTax = ltcgTax(gain: gain, income: income, status: status)
        } else {
            federalTax = stackedBracketTax(existingIncome: income, additionalIncome: gain, status: status)
        }
        let federalRate = gain > 0 ? (federalTax / gain * 100).rounded(to: 2) : 0

        // NIIT
        let magi = income + gain
        let niit = calculateNIIT(magi: magi, netInvestmentIncome: gain, status: status)

        // State
        let stateTax = calculateStateTax(gain: gain, isLT: isLT, income: income, status: status)
        let stateRate = gain > 0 ? (stateTax / gain * 100).rounded(to: 2) : 0

        // City
        let cityTax = calculateCityTax(gain: gain, isLT: isLT, income: income,
                                        status: status, stateTax: stateTax)
        let cityRate = gain > 0 ? (cityTax / gain * 100).rounded(to: 2) : 0

        let total = (federalTax + niit + stateTax + cityTax).rounded(to: 2)

        return TaxEstimate(
            gain: gain,
            isLongTerm: isLT,
            isSection1256: isSection1256,
            federalTax:  federalTax.rounded(to: 2),
            federalRate: federalRate,
            niit:        niit.rounded(to: 2),
            stateTax:    stateTax.rounded(to: 2),
            stateRate:   stateRate,
            cityTax:     cityTax.rounded(to: 2),
            cityRate:    cityRate,
            totalTax:    total,
            netProceeds: (gain - total).rounded(to: 2),
            washSaleWarning: washSaleWarning,
            amtWarning: gain > 100_000
        )
    }

    // MARK: - Holding period (366-day IRS rule)

    func isLongTerm(purchaseDate: Date, saleDate: Date) -> Bool {
        let cal = Calendar.current
        guard let anniversary = cal.date(byAdding: .year, value: 1, to: purchaseDate) else {
            return false
        }
        return saleDate > anniversary   // strictly AFTER one-year anniversary
    }

    // MARK: - Federal stacked bracket (ordinary income / ST gains)

    func stackedBracketTax(
        existingIncome: Decimal,
        additionalIncome: Decimal,
        status: FilingStatus
    ) -> Decimal {
        let brackets = rates.federal.ordinary.brackets(for: status)
        return applyBrackets(brackets, existing: existingIncome, additional: additionalIncome)
    }

    // MARK: - LTCG tax (brackets stack on top of ordinary income)

    func ltcgTax(gain: Decimal, income: Decimal, status: FilingStatus) -> Decimal {
        let brackets = rates.federal.ltcg.brackets(for: status)
        return applyBrackets(brackets, existing: income, additional: gain)
    }

    // MARK: - NIIT

    func calculateNIIT(magi: Decimal, netInvestmentIncome: Decimal, status: FilingStatus) -> Decimal {
        let threshold = rates.federal.niit.thresholds.threshold(for: status)
        guard magi > threshold else { return 0 }
        let excess   = magi - threshold
        let subject  = min(netInvestmentIncome, excess)
        return subject * rates.federal.niit.rate
    }

    // MARK: - State tax

    func calculateStateTax(
        gain: Decimal,
        isLT: Bool,
        income: Decimal,
        status: FilingStatus
    ) -> Decimal {
        guard let code = profile.state,
              let st   = rates.states[code] else { return 0 }

        switch st.type {
        case .none:
            return 0

        case .flat:
            if st.distinguishesLongTerm ?? false {
                let rate = isLT ? (st.ltRate ?? st.rate ?? 0) : (st.stRate ?? st.rate ?? 0)
                return (gain * rate).rounded(to: 2)
            }
            return (gain * (st.rate ?? 0)).rounded(to: 2)

        case .graduated:
            guard let brackets = st.brackets?.brackets(for: status), !brackets.isEmpty else { return 0 }
            // Most states tax CG as ordinary income, stacked on existing income
            return applyBrackets(brackets, existing: income, additional: gain).rounded(to: 2)

        case .capitalGains:
            // WA: flat rate on gains above threshold
            guard let ltcgRate  = st.ltcgRate,
                  let threshold = st.ltcgThreshold else { return 0 }
            let taxable = max(0, gain - threshold)
            return (taxable * ltcgRate).rounded(to: 2)
        }
    }

    // MARK: - City tax

    func calculateCityTax(
        gain: Decimal,
        isLT: Bool,
        income: Decimal,
        status: FilingStatus,
        stateTax: Decimal
    ) -> Decimal {
        guard let cityKey = profile.city,
              let city    = rates.cities[cityKey] else { return 0 }

        // Check if this gain type applies
        let appliesToST = city.appliesTo.contains("shortTerm")
        let appliesToLT = city.appliesTo.contains("longTerm")
        let applies = city.appliesTo.isEmpty || (isLT ? appliesToLT : appliesToST)
        guard applies else { return 0 }

        switch city.type {
        case "flat":
            let rate = profile.isResident
                ? (city.rate ?? 0)
                : (city.nonResidentRate ?? city.rate ?? 0)
            return (gain * rate).rounded(to: 2)

        case "graduated":
            guard let brackets = city.brackets?.brackets(for: status), !brackets.isEmpty else { return 0 }
            return applyBrackets(brackets, existing: income, additional: gain).rounded(to: 2)

        case "surcharge":
            // Yonkers: resident surcharge is a % of state tax owed
            let rate = profile.isResident
                ? (city.surchargeRate ?? 0)
                : (city.nonResidentRate ?? 0)
            return (stateTax * rate).rounded(to: 2)

        default:
            return 0
        }
    }

    // MARK: - Private bracket math

    private func applyBrackets(
        _ brackets: [TaxBracket],
        existing: Decimal,
        additional: Decimal
    ) -> Decimal {
        var tax: Decimal     = 0
        var remaining        = additional
        var current          = existing

        for b in brackets {
            guard remaining > 0 else { break }
            let top = b.max ?? Decimal(1_000_000_000)
            guard current < top else { continue }
            let start   = max(current, b.min)
            let space   = top - start
            let taxable = min(remaining, space)
            tax       += taxable * b.rate
            remaining -= taxable
            current    = start + taxable
        }
        return tax
    }
}

// MARK: - Convenience factory

extension TaxEngine {
    /// Creates a TaxEngine from the bundled rates + shared profile.
    static func makeDefault() -> TaxEngine {
        TaxEngine(rates: TaxRatesLoader.load(), profile: TaxProfileManager.shared.profile)
    }
}

// MARK: - Wash sale check

extension TaxEngine {
    /// Returns true if selling `lot` from `holding` at a loss and a re-purchase
    /// of the same symbol occurred within 30 days before the sale date.
    static func washSaleWarning(
        lot: Lot,
        holding: Holding,
        saleDate: Date,
        realizedPnL: Decimal,
        allLots: [Lot]
    ) -> Bool {
        guard realizedPnL < 0 else { return false }
        let window: TimeInterval = 30 * 24 * 60 * 60
        let windowStart = saleDate.addingTimeInterval(-window)
        return allLots.contains { other in
            other.holdingId == holding.id
            && other.id != lot.id
            && other.purchaseDate >= windowStart
            && other.purchaseDate <= saleDate
        }
    }
}
