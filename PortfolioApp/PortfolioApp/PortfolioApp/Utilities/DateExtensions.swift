import Foundation

extension Date {

    // MARK: - Long-Term Capital Gains (IRS Rule)

    /// IRS rule: asset must be held MORE THAN 12 months.
    /// The sale date must be STRICTLY AFTER the 1-year anniversary of the purchase (trade) date.
    ///
    /// Examples:
    ///   Bought Jan 15 2025 → LT requires sale on Jan 16 2026 or later
    ///   Bought Feb 29 2024 (leap) → 1yr = Feb 28 2025, LT requires Mar 1 2025 or later
    ///   Swift Calendar.date(byAdding:) handles all leap year edge cases automatically.
    func isLongTerm(purchasedOn purchaseDate: Date) -> Bool {
        guard let oneYearAnniversary = Calendar.current.date(byAdding: .year, value: 1, to: purchaseDate) else {
            return false
        }
        return self > oneYearAnniversary // strictly after
    }

    /// The exact calendar date on which LT status is first achieved.
    /// This is the day AFTER the 1-year anniversary.
    static func longTermQualifyingDate(purchasedOn purchaseDate: Date) -> Date? {
        let cal = Calendar.current
        guard let anniversary = cal.date(byAdding: .year, value: 1, to: purchaseDate) else { return nil }
        return cal.date(byAdding: .day, value: 1, to: anniversary)
    }

    // MARK: - Days Held / Days To LT

    /// Calendar days from purchaseDate to this date (trade date).
    func daysHeld(from purchaseDate: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: purchaseDate, to: self).day ?? 0)
    }

    /// Days remaining until the first qualifying LT sale date.
    /// Returns nil if this date already qualifies as LT.
    func daysToLongTerm(purchasedOn purchaseDate: Date) -> Int? {
        guard let qualifyingDate = Date.longTermQualifyingDate(purchasedOn: purchaseDate) else { return nil }
        if self >= qualifyingDate { return nil }
        return Calendar.current.dateComponents([.day], from: self, to: qualifyingDate).day
    }

    /// Progress toward LT as a fraction [0, 1].
    /// UI label convention: show "X / 366 days" — this is a consistent UI representation,
    /// not a literal day count (actual LT is date-based, not day-count-based).
    func ltProgress(purchasedOn purchaseDate: Date) -> Double {
        let held = daysHeld(from: purchaseDate)
        return min(Double(held) / 366.0, 1.0)
    }

    // MARK: - Trade Date vs Settlement Date

    /// Returns the settlement date assuming T+1 (stocks, ETFs after May 2024).
    var settlementDateT1: Date? {
        Calendar.current.date(byAdding: .day, value: 1, to: self)
    }

    /// Returns the settlement date assuming T+2 (older standard, options).
    var settlementDateT2: Date? {
        Calendar.current.date(byAdding: .day, value: 2, to: self)
    }

    // MARK: - Formatting

    var shortFormatted: String {
        formatted(date: .abbreviated, time: .omitted)
    }

    var mediumFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    var isoDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: self)
    }

    // MARK: - Relative Descriptions

    var timeAgoDescription: String {
        let seconds = Int(-timeIntervalSinceNow)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    var minutesSince: Int {
        Int(-timeIntervalSinceNow / 60)
    }

    var isOlderThan15Minutes: Bool {
        minutesSince > 15
    }

    // MARK: - Market Hours

    /// Whether US equity markets are currently open (9:30 AM – 4:00 PM ET, Mon–Fri).
    /// Does not account for market holidays (use MarketCalendar for that).
    static var isUSMarketHours: Bool {
        var calendar = Calendar(identifier: .gregorian)
        guard let easternTimeZone = TimeZone(identifier: "America/New_York") else { return false }
        calendar.timeZone = easternTimeZone

        let now = Date()
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute else { return false }

        // 2 = Monday, 6 = Friday
        guard weekday >= 2 && weekday <= 6 else { return false }

        let minutesSinceMidnight = hour * 60 + minute
        let marketOpen = 9 * 60 + 30  // 9:30 AM
        let marketClose = 16 * 60     // 4:00 PM

        return minutesSinceMidnight >= marketOpen && minutesSinceMidnight < marketClose
    }

    // MARK: - I-Bond Specific

    /// I-Bond lockup uses the first day of the purchase month (TreasuryDirect convention),
    /// not the exact purchase date.
    var iBondIssueDate: Date {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: self)
        return cal.date(from: components) ?? self
    }

    /// The date 1 year after the I-Bond issue date (redeemable after this).
    var iBondRedeemableDate: Date? {
        Calendar.current.date(byAdding: .year, value: 1, to: iBondIssueDate)
    }

    /// The date 5 years after the I-Bond issue date (no penalty after this).
    var iBondPenaltyFreeDate: Date? {
        Calendar.current.date(byAdding: .year, value: 5, to: iBondIssueDate)
    }
}
