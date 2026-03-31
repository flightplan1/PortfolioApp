# Tax Module

## Critical Rules

1. **Never apply marginal rate to full gain** — brackets must stack
2. **LT threshold = 366 days** (strictly more than 12 months per IRS)
3. **Trade date determines holding period** — not settlement date
4. **Default income = $70,000** when no tax profile set
5. **Default filing status = Single** when no tax profile set
6. **All displayed tax figures carry `~` tilde prefix**
7. **Four tax layers always stacked:** Federal + NIIT + State + City

---

## Tax Layer Stack

```
Capital Gain
    ↓
Federal (bracket-stacked, LT or ST)
    ↓
NIIT 3.8% (if MAGI > threshold)
    ↓
State (graduated or flat, per tax-rates.json)
    ↓
City / Local (graduated or flat, per tax-rates.json)
    ↓
= Total estimated tax
    ↓
Net proceeds after all taxes
```

---

## Federal Tax — Bracket Stacking Algorithm

Short-term gains are taxed as ordinary income, stacked ON TOP of existing salary.

```swift
func stackedBracketTax(
    existingIncome: Decimal,    // user's salary
    additionalIncome: Decimal,  // the capital gain
    brackets: [TaxBracket]
) -> Decimal {
    var tax: Decimal = 0
    var remaining = additionalIncome
    var currentIncome = existingIncome

    for bracket in brackets {
        guard remaining > 0 else { break }
        let bracketTop = bracket.max ?? Decimal.greatestFiniteMagnitude
        if currentIncome >= bracketTop { continue }

        let spaceInBracket = bracketTop - max(currentIncome, bracket.min)
        let taxableInBracket = min(remaining, spaceInBracket)

        tax += taxableInBracket * bracket.rate
        remaining -= taxableInBracket
        currentIncome = max(currentIncome, bracket.min) + taxableInBracket
    }
    return tax
}
```

Long-term gains use the LTCG brackets separately (0% / 15% / 20%).

---

## NIIT (Net Investment Income Tax)

Rate: 3.8%
Applies to: **lesser of** net investment income OR amount by which MAGI exceeds threshold.

```swift
func calculateNIIT(magi: Decimal, netInvestmentIncome: Decimal, filingStatus: FilingStatus) -> Decimal {
    let threshold: Decimal = filingStatus == .mfj ? 250000 : 200000
    guard magi > threshold else { return 0 }
    let excessMAGI = magi - threshold
    let subjectToNIIT = min(netInvestmentIncome, excessMAGI)
    return subjectToNIIT * 0.038
}
```

---

## State Tax Rules

State rates loaded from `tax-rates.json`. Key flags per state:

- `distinguishesLongTerm: Bool` — if false, apply ordinary income rate regardless of LT/ST
- `type: "flat" | "graduated" | "none"`
- States with no income tax: AK, FL, NV, SD, TN, TX, WA (WA has 7% CG tax above $262k threshold), WY, NH

**CA, NY, NJ, OR** — do NOT offer preferential LTCG rates. All gains taxed as ordinary income at state level.

---

## City Tax Rules

- `residentOnly: Bool` — some cities only tax residents
- `nonResidentRate: Decimal` — different rate for non-residents
- `appliesTo: ["shortTerm", "longTerm"]` — some cities only tax one type

**Notable cities:**
- New York City: graduated 3.078%–3.876% (most significant city tax in US)
- Philadelphia: 3.75% residents / 3.5% non-residents
- Detroit: 2.4% residents / 1.2% non-residents
- Yonkers: 1.6752% surcharge on NY state tax

---

## Section 1256 (Index Options)

Qualifying symbols: SPX, SPXW, NDXP, NDX, RUT, VIX, XSP and other broad-based index options.

60% of gain taxed at LTCG rate, 40% at ordinary income rate — regardless of holding period.

```swift
func section1256Tax(gain: Decimal, ...) -> Decimal {
    let ltPortion = gain * 0.60
    let stPortion = gain * 0.40
    return calculateLTCGTax(gain: ltPortion, ...) +
           stackedBracketTax(additionalIncome: stPortion, ...)
}
```

---

## Holding Period — LT/ST Determination

```swift
// IRS rule: must be held MORE THAN 12 months
// Sale date must be STRICTLY AFTER the 1-year anniversary of purchase

func isLongTerm(purchaseDate: Date, saleDate: Date) -> Bool {
    let calendar = Calendar.current
    let oneYearAnniversary = calendar.date(
        byAdding: .year, value: 1, to: purchaseDate
    )!
    return saleDate > oneYearAnniversary  // strictly after
}

// Examples:
// Bought Jan 15 2025 → LT requires sale Jan 16 2026 or later
// Bought Feb 29 2024 (leap) → one year = Feb 28 2025 (non-leap)
// Swift Calendar handles leap year edge cases automatically
```

Progress bar shows "X / 366 days" — never "365 days".
Qualifying date shown as exact date, not day count.

---

## Tax-Free Scenarios

- **Treasury interest** — exempt from state and city tax (federal only)
- **T-Bill discount gain** — also state/city exempt (same as coupon interest)
- **DRIP reinvestment** — not taxed as income at lot creation; taxed when lot is eventually sold
- **Cash-to-cash transfers** — not taxable events

---

## Taxable Events

- Selling stock/ETF/crypto/options for any price
- Crypto-to-crypto swap (flagged with warning in UI)
- DRIP dividend receipt (dividend portion is income even if reinvested)
- Cash dividends received
- Options expiring worthless (loss on expiry date)
- TIPS inflation adjustment (phantom income — flagged prominently)

---

## Wash Sale Rules

- **Applies to:** Stocks, ETFs, Options
- **Does NOT apply to:** Crypto (as of 2026 — subject to legislative change, show warning)
- **Window:** 30 days before OR after the sale
- **Effect:** Disallowed loss added to cost basis of repurchased security
- **Detection:** Flag in UI when sell-at-loss + same symbol purchased within 30 days

---

## Tax Rates JSON — Remote Update Strategy (Option C+D)

- Bundled: `Resources/tax-rates.json` (current version)
- Remote: User's private GitHub raw URL (set in Settings)
- Check: On app launch + once per month
- Fallback: Use last cached version if remote unreachable
- Version format: `"2026.1"` (year.revision)
- New year detection: If effectiveYear < current year → show persistent banner:
  "Tax rates may be outdated — please verify and update"

```swift
// TaxRatesLoader.swift
func loadRates() async -> TaxRates {
    if let remote = await fetchRemoteRates(), remote.version > localVersion {
        cache(remote)
        return remote
    }
    return localCachedRates ?? bundledRates
}
```

---

## AMT Warning

App does NOT calculate AMT. For any sale where gain > $100,000:
Show: "Large gains may trigger Alternative Minimum Tax (AMT). Consult a tax professional."

---

## Disclaimer System

### Three tiers — use the right one per context:

**Tier 1 — Short (footers, persistent)**
> *Estimated only · Not tax advice*

**Tier 2 — Medium (inline with numbers)**
> *Tax figures are estimates based on your profile. Actual liability may differ. Not tax advice.*

**Tier 3 — Full (sell sheet, onboarding)**
> *All tax calculations are estimates only, based on the cost basis and tax profile information you have entered. They do not constitute tax advice and may differ from your actual tax liability. Figures do not account for AMT, carry-forward losses, state-specific deductions, or wash sale adjustments. Consult a qualified tax professional before making investment decisions based on these estimates.*

### Placement rules:
- Sell sheet: Tier 3 at TOP (before numbers), Tier 1 at BOTTOM
- Lot cards: Tier 2 inline inside tax estimate box
- Lots tab footer: Tier 1 persistent card
- P&L Realized tab year summary: Tier 1
- Dashboard realized card: `~` tilde on estimated values
- Settings tax profile footer: Tier 1
- CSV export header: Full disclaimer as comment rows
- Onboarding completion: Tier 3 with acknowledgement tap

### `~` tilde convention:
All estimated monetary values display `~` prefix or suffix.
All estimated tax line items include `~` in their label.
Users learn: `~` = estimated.

### Tax profile incomplete banner (non-dismissible):
```
⚠️ Tax profile incomplete
Estimates shown use Single filer, $70k income defaults
and may be significantly inaccurate.
[Complete your profile →]
```
