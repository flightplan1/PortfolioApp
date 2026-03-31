import Foundation

extension Decimal {

    // MARK: - Rounding

    /// Bankers rounding to N decimal places. Use for all financial calculations.
    func rounded(to places: Int) -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, places, .bankers)
        return result
    }

    // MARK: - Formatting

    var asCurrency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: self as NSDecimalNumber) ?? "$0.00"
    }

    var asCurrencyCompact: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.usesGroupingSeparator = true
        if abs(self) >= 1_000_000 {
            formatter.maximumFractionDigits = 1
            let millions = (self / 1_000_000).rounded(to: 1)
            return (formatter.string(from: millions as NSDecimalNumber) ?? "") + "M"
        } else if abs(self) >= 1_000 {
            formatter.maximumFractionDigits = 1
            let thousands = (self / 1_000).rounded(to: 1)
            return (formatter.string(from: thousands as NSDecimalNumber) ?? "") + "K"
        }
        return asCurrency
    }

    /// "±$1,234.56" — always shows sign
    var asCurrencySigned: String {
        let abs = asCurrency
        return self >= 0 ? "+\(abs)" : abs
    }

    /// "1.23%" with 2 decimal places
    func asPercent(decimalPlaces: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimalPlaces
        formatter.maximumFractionDigits = decimalPlaces
        let str = formatter.string(from: self as NSDecimalNumber) ?? "0"
        return "\(str)%"
    }

    /// "±1.23%" — always shows sign
    func asPercentSigned(decimalPlaces: Int = 2) -> String {
        let str = asPercent(decimalPlaces: decimalPlaces)
        return self >= 0 ? "+\(str)" : str
    }

    /// Plain decimal number string (e.g. "0.5" for crypto quantities)
    func asQuantity(maxDecimalPlaces: Int = 8) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxDecimalPlaces
        formatter.usesGroupingSeparator = true
        return formatter.string(from: self as NSDecimalNumber) ?? "0"
    }

    // MARK: - Conversions

    /// Safe conversion from Double — avoids floating point precision errors
    static func from(_ double: Double) -> Decimal {
        Decimal(string: String(double)) ?? Decimal(double)
    }

    static func from(_ string: String) -> Decimal? {
        Decimal(string: string)
    }

    var isNaN: Bool { self == Decimal.nan }

    var isFinite: Bool { !isNaN && !isInfinite }

    var isInfinite: Bool {
        // Decimal doesn't have infinity but guard against divide-by-zero results
        false
    }

    // MARK: - Safe Division

    func divided(by divisor: Decimal) -> Decimal? {
        guard divisor != 0 else { return nil }
        return self / divisor
    }

    func percentageOf(_ total: Decimal) -> Decimal {
        guard total != 0 else { return 0 }
        return ((self / total) * 100).rounded(to: 4)
    }
}

// MARK: - NSDecimalNumber Bridge

extension NSDecimalNumber {
    static let zero = NSDecimalNumber(decimal: 0)
}
