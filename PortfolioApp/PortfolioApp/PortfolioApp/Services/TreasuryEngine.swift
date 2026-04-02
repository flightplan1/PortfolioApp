import Foundation

// MARK: - TreasuryEngine
// Pure calculation functions for US Treasury instruments.
// All inputs/outputs in Decimal for financial precision.

enum TreasuryEngine {

    // MARK: - YTM at Purchase (dispatch by instrument type)

    static func ytmAtPurchase(
        instrument: TreasuryInstrument,
        faceValue: Decimal,
        purchasePrice: Decimal,
        couponRate: Decimal,
        purchaseDate: Date,
        maturityDate: Date
    ) -> Decimal {
        let days = Calendar.current.dateComponents([.day], from: purchaseDate, to: maturityDate).day ?? 0
        guard days > 0, purchasePrice > 0, faceValue > 0 else { return 0 }

        switch instrument {
        case .tBill:
            return tBillBEY(faceValue: faceValue, purchasePrice: purchasePrice, days: days)
        case .tNote, .tBond:
            let years = Decimal(days) / 365
            let annualCoupon = faceValue * couponRate
            return bondYTMApprox(faceValue: faceValue, purchasePrice: purchasePrice,
                                 annualCoupon: annualCoupon, years: years)
        case .tips:
            let years = Decimal(days) / 365
            // Real YTM for TIPS uses face value (not inflation-adjusted) at purchase
            let annualCoupon = faceValue * couponRate
            return bondYTMApprox(faceValue: faceValue, purchasePrice: purchasePrice,
                                 annualCoupon: annualCoupon, years: years)
        case .iBond:
            // For I-Bonds, YTM is not a standard metric; return composite rate
            return 0
        }
    }

    // MARK: - T-Bill Bond Equivalent Yield
    // BEY = ((FaceValue - PurchasePrice) / PurchasePrice) × (365 / days)

    static func tBillBEY(faceValue: Decimal, purchasePrice: Decimal, days: Int) -> Decimal {
        guard purchasePrice > 0, days > 0 else { return 0 }
        let discount = faceValue - purchasePrice
        let yield = (discount / purchasePrice) * (365 / Decimal(days))
        return yield.rounded(to: 6)
    }

    // MARK: - Bond YTM Approximation
    // YTM ≈ (Annual Coupon + (FV - PP) / years) / ((FV + PP) / 2)
    // Accurate to within ~15bps for bonds near par; sufficient for display purposes.

    static func bondYTMApprox(
        faceValue: Decimal,
        purchasePrice: Decimal,
        annualCoupon: Decimal,
        years: Decimal
    ) -> Decimal {
        guard years > 0, purchasePrice > 0 else { return 0 }
        let numerator   = annualCoupon + (faceValue - purchasePrice) / years
        let denominator = (faceValue + purchasePrice) / 2
        guard denominator > 0 else { return 0 }
        return (numerator / denominator).rounded(to: 6)
    }

    // MARK: - Accrued Interest (Actual/Actual, ICMA)
    // Used for T-Note, T-Bond, TIPS when settling between coupon dates.
    // accrued = (faceValue × couponRate / paymentsPerYear) × (daysSinceLast / daysInPeriod)

    static func accruedInterest(
        faceValue: Decimal,
        couponRate: Decimal,
        paymentsPerYear: Int,
        daysSinceLastCoupon: Int,
        daysInCouponPeriod: Int
    ) -> Decimal {
        guard paymentsPerYear > 0, daysInCouponPeriod > 0 else { return 0 }
        let periodCoupon = faceValue * couponRate / Decimal(paymentsPerYear)
        return (periodCoupon * Decimal(daysSinceLastCoupon) / Decimal(daysInCouponPeriod)).rounded(to: 2)
    }

    // MARK: - Estimated Current Value

    /// T-Bill: PV = FaceValue / (1 + ytm × days/365)
    static func tBillCurrentValue(faceValue: Decimal, ytm: Decimal, daysToMaturity: Int) -> Decimal {
        guard daysToMaturity > 0 else { return faceValue }
        let divisor = 1 + ytm * Decimal(daysToMaturity) / 365
        guard divisor > 0 else { return faceValue }
        return (faceValue / divisor).rounded(to: 2)
    }

    /// Coupon bond: sum of discounted cash flows (simplified — assumes flat yield curve).
    static func bondCurrentValue(
        faceValue: Decimal,
        couponRate: Decimal,
        paymentsPerYear: Int,
        ytm: Decimal,
        daysToMaturity: Int
    ) -> Decimal {
        guard paymentsPerYear > 0, ytm > 0, daysToMaturity > 0 else { return faceValue }
        let periodsRemaining = Decimal(daysToMaturity) / Decimal(365 / paymentsPerYear)
        let periodicRate     = ytm / Decimal(paymentsPerYear)
        let periodicCoupon   = faceValue * couponRate / Decimal(paymentsPerYear)

        // PV of annuity + PV of face value
        let n      = periodsRemaining
        let r      = periodicRate
        guard r > 0 else { return faceValue }
        // (1 - (1+r)^-n) / r  — using logarithms since Decimal has no pow()
        let base   = 1 + r
        let factor = decimalPow(base: base, exponent: -n)
        let annuityFactor = (1 - factor) / r
        let pv     = periodicCoupon * annuityFactor + faceValue * factor
        return pv.rounded(to: 2)
    }

    // MARK: - I-Bond Composite Rate
    // composite = fixedRate + 2 × semiannualCPI + fixedRate × semiannualCPI

    static func iBondCompositeRate(fixedRate: Decimal, semiannualCPI: Decimal) -> Decimal {
        let composite = fixedRate + 2 * semiannualCPI + fixedRate * semiannualCPI
        return composite.rounded(to: 6)
    }

    /// Estimated I-Bond value after holding from purchaseDate.
    /// Simplified: applies composite rate semiannually.
    static func iBondCurrentValue(
        purchasePrice: Decimal,
        compositeRate: Decimal,
        purchaseDate: Date
    ) -> Decimal {
        let months = Calendar.current.dateComponents([.month], from: purchaseDate, to: Date()).month ?? 0
        let periods = Decimal(months / 6)  // full semiannual periods
        guard periods > 0 else { return purchasePrice }
        let semiannualRate = compositeRate / 2
        let growth = decimalPow(base: 1 + semiannualRate, exponent: periods)
        return (purchasePrice * growth).rounded(to: 2)
    }

    // MARK: - Coupon Payment Schedule

    static func couponDates(from start: Date, to end: Date, frequency: CouponFrequency) -> [Date] {
        guard frequency != .zero else { return [] }
        let monthsPerPeriod = frequency == .semiannual ? 6 : 12
        var dates: [Date] = []
        var current = start
        let cal = Calendar.current
        while let next = cal.date(byAdding: .month, value: monthsPerPeriod, to: current), next <= end {
            dates.append(next)
            current = next
        }
        return dates
    }

    // MARK: - Helpers

    /// Decimal approximation of base^exponent using exp(exponent × ln(base)).
    /// Sufficient precision for bond pricing (< 1bp error for typical inputs).
    private static func decimalPow(base: Decimal, exponent: Decimal) -> Decimal {
        guard base > 0 else { return 0 }
        let b = Double(truncating: base as NSNumber)
        let e = Double(truncating: exponent as NSNumber)
        let result = Foundation.pow(b, e)
        return Decimal(result)
    }
}
