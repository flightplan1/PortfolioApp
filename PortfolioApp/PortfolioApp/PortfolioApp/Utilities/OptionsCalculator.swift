import Foundation

// MARK: - Options Calculator
// All options calculations MUST go through this struct — never inline math.
// 1 contract = 100 shares. This multiplier is always applied.

struct OptionsCalculator {

    static let sharesPerContract = 100

    // MARK: - Cost Calculations

    /// Total cost to open an options position.
    /// totalCost = (contracts × premiumPerShare × 100) + fee
    static func totalCost(
        contracts: Int,
        premiumPerShare: Decimal,
        fee: Decimal
    ) -> Decimal {
        (Decimal(contracts) * premiumPerShare * Decimal(sharesPerContract)) + fee
    }

    /// Cost basis per share (for P&L calculation).
    /// Includes fee amortized across all shares.
    /// avgCostPerShare = totalCost / (contracts × 100)
    static func avgCostPerShare(
        contracts: Int,
        premiumPerShare: Decimal,
        fee: Decimal
    ) -> Decimal {
        let totalShares = Decimal(contracts * sharesPerContract)
        guard totalShares > 0 else { return 0 }
        let total = totalCost(contracts: contracts, premiumPerShare: premiumPerShare, fee: fee)
        return total / totalShares
    }

    // MARK: - P&L Calculations

    /// Unrealized P&L for an open options position.
    /// pnl = (currentPrice - avgCostPerShare) × contracts × 100
    static func unrealizedPnL(
        contracts: Int,
        currentPrice: Decimal,
        avgCostPerShare: Decimal
    ) -> Decimal {
        (currentPrice - avgCostPerShare) * Decimal(contracts) * Decimal(sharesPerContract)
    }

    /// Realized P&L when closing/selling an options position.
    /// pnl = (salePrice - avgCostPerShare) × contracts × 100 - closingFee
    static func realizedPnL(
        contracts: Int,
        salePrice: Decimal,
        avgCostPerShare: Decimal,
        closingFee: Decimal = 0
    ) -> Decimal {
        let gross = (salePrice - avgCostPerShare) * Decimal(contracts) * Decimal(sharesPerContract)
        return gross - closingFee
    }

    /// P&L when an option expires worthless.
    /// loss = -(totalCostBasis)
    static func expiryLoss(totalCostBasis: Decimal) -> Decimal {
        -totalCostBasis
    }

    // MARK: - Display

    /// Human-readable representation of the options position size.
    /// e.g. "2 contracts × 100 shares = 200 share equivalent"
    static func positionSizeDescription(contracts: Int) -> String {
        let shareEquivalent = contracts * sharesPerContract
        return "\(contracts) contract\(contracts == 1 ? "" : "s") × 100 shares = \(shareEquivalent) share equivalent"
    }

    /// Total share equivalent for a given contract count.
    static func shareEquivalent(contracts: Int) -> Int {
        contracts * sharesPerContract
    }

    // MARK: - Section 1256

    /// Section 1256 contracts (SPX, NDX, RUT, VIX, etc.) receive 60/40 tax treatment:
    /// 60% of gain taxed at LT rate, 40% at ST (ordinary income) rate — regardless of holding period.
    static let section1256LTPortion: Decimal = 0.60
    static let section1256STPortion: Decimal = 0.40

    /// Qualifying symbols for Section 1256 treatment.
    /// Includes broad-based index options only — equity options do NOT qualify.
    static let section1256Symbols: Set<String> = [
        "SPX", "SPXW", "SPXPM",
        "NDX", "NDXP",
        "RUT",
        "VIX",
        "XSP",
        "DJX",
        "OEX", "XEO"
    ]

    static func isSection1256(symbol: String) -> Bool {
        section1256Symbols.contains(symbol.uppercased())
    }
}
