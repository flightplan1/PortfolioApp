# Features

## Asset Types

| Type | Price Source | Tax Treatment | Notes |
|---|---|---|---|
| Stock | Finnhub | ST/LT capital gains | Standard |
| ETF | Finnhub | ST/LT capital gains | Same as stock |
| Crypto | CoinGecko | Property (same as stock) | No wash sale rule (as of 2026) |
| Options | Finnhub (limited) / manual | ST or Section 1256 | ×100 multiplier always applied |
| Cash | N/A | Interest = ordinary income | Balance tracking only |
| Money Market | Finnhub (ticker) / manual | Interest = ordinary income | Near-cash |
| T-Bill | N/A (manual) | Federal only, state/city exempt | Zero-coupon |
| T-Note | N/A (manual) | Federal only, state/city exempt | Semi-annual coupon |
| T-Bond | N/A (manual) | Federal only, state/city exempt | Semi-annual coupon |
| TIPS | N/A (manual) | Federal only; inflation adj = phantom income | Principal adjusts with CPI |
| I-Bond | N/A (manual) | Federal only (deferred until redemption) | $10k/yr limit, 1yr lockup |

---

## Screen Architecture

```
App (SwiftUI TabView)
├── Dashboard
├── Holdings
├── P&L
├── News & Earnings
└── Settings
```

### Dashboard
- Total portfolio value (with hide/show toggle)
- Unrealized P&L (all-time, $ and %)
- Today's change ($ and %)
- Portfolio allocation donut chart (by asset type)
- Cash available to deploy
- Treasury summary (total value, avg YTM, next maturity)
- Upcoming earnings widget (next 2 events)
- Today's top movers
- Cash drag calculation (informational)
- 2026 Realized P&L compact strip

### Holdings Tab
- Filter chips: All / Stock / ETF / Crypto / Options / Cash / Treasury
- Per-position card: symbol, type chip, DRIP chip, value, unrealized P&L, daily P&L
- Cash positions section (balance, APY, yield estimate)
- Treasury positions section (face value, YTM, maturity, accrued interest, days to maturity)
- Tap any position → Position Detail Screen

### Position Detail Screen (5 tabs)
**Overview tab:**
- Price + daily change
- 52-week price sparkline + range bar
- 6 position stats: market value, unrealized P&L, daily P&L, shares, avg cost, total cost
- Market data: open, prev close, high, low, volume, P/E, beta, dividend yield
- Next earnings card (date, time, est EPS, last EPS, est/last revenue)
- Split history (with APPLIED ✓ badge)
- Buy More + Sell buttons
- View Industry Dependencies button

**Lots tab:**
- Holding period summary (LT/ST breakdown with progress bar)
- Per-lot card:
  - Lot number, LT/ST badge, SPLIT ADJ badge if applicable
  - Quantity, purchase date
  - Cost basis, market value, held days
  - Progress bar to LT (with exact qualifying date, "X / 366 days")
  - Gold advisory if daysToLT ≤ 60 (estimated tax saving shown)
  - Tax estimate box: est. federal tax + est. after-tax gain (both with `~`)
  - Inline Tier 2 disclaimer inside tax box
  - "Sell Specific Lot →" button
- Lots tab footer: Tier 1 disclaimer card
- Default lot method note + Settings link

**Dividends tab:**
- DRIP toggle
- Annual yield estimate, YTD received/reinvested
- Next ex-dividend date estimate
- Dividend history: each entry shows gross amount, date, reinvested/cash, shares acquired, new lot created

**News tab:**
- Per-symbol articles: sentiment dot, source, age, headline
- Breaking news badge on articles < 1 hour old
- Upcoming earnings card (same as Overview)

**Industry tab:**
- Sector + subindustry label
- Upstream companies (supplies to this stock) with "In Portfolio" badge
- Downstream companies (depends on this stock) with "In Portfolio" badge
- Downstream sector exposure bar chart

### Sell Sheet (Bottom Sheet)
- Lot identifier + shares available
- Tier 3 disclaimer at top (gold warning card)
- LT advisory if close to LT threshold (estimated tax saving)
- Quantity slider
- Tax breakdown: Gross proceeds, cost basis (entered), capital gain
- Four tax layers: Federal~ + State~ + City~ + Total est. tax~
- Net proceeds (green card): "Est. net proceeds ~"
- Tier 1 disclaimer at bottom (filing status + income + "Verify with broker")
- Cancel + Confirm Sell buttons

### P&L Tab
- Summary strip: Unrealized, Today, Realized YTD (3 cards)
- Holding period breakdown (LT/ST/Approaching with progress bars)
- Tab toggle: Open Positions / Realized
- Open positions: per-holding with 3 stat tiles (unrealized, daily, return)
- Realized tab: per-transaction with federal/state/city/net breakdown
- Tax year summary with all layers + full Tier 1 disclaimer

### News & Earnings Tab
- Tab toggle: News Feed / Earnings Calendar
- News feed: sentiment dot, source, age, headline, breaking badge
- Earnings calendar: week-at-a-glance, per-holding entries, est vs actual EPS

### Settings Tab
- Tax Profile: filing status, annual income ($70k default), state, city, lot method
- Dividends & DRIP: default DRIP toggle, default bank fee
- Alerts: options expiry thresholds, split detection, breaking news, LT warning threshold
- Security: biometric lock toggle, lock-after duration, hide in app switcher
- Cash Positions: auto-deduct on buy, auto-add on sell, show cash drag
- Treasury: default maturity alert, coupon alerts, I-Bond rate reminder
- Tax Rates: version display, remote URL config
- Persistent footer: "Tax figures throughout the app are estimates only. Not tax advice."

---

## Key Features — Detail

### DRIP (Dividend Reinvestment)
- Each reinvestment creates a NEW LOT with that day's price as cost basis
- New lot appears in lot picker immediately
- DRIP lots tagged with `lotSource = .drip` and `linkedDividendEventId`
- Dividend receipt is taxable income even when reinvested (shown in tax year summary)
- Auto-prompt on pay date: "Dividend received — confirm reinvestment?"

### Stock Splits
- Auto-detected via Finnhub `/stock/split` on app launch
- Always requires user confirmation before applying — never silent
- Atomic CoreData transaction: all lots for symbol adjust together
- SplitSnapshot saved for 24-hour revert window
- Lot fields preserved: `originalQty`, `originalCostBasisPerShare`
- Split-adjusted fields updated: `splitAdjustedQty`, `splitAdjustedCostBasisPerShare`
- Total cost basis NEVER changes through splits
- Reverse splits: prompt for fractional share cash-out option
- Options on split stocks: freeze P&L calculation, show "OCC Adjusted — verify with broker"
- Historical (pre-app) splits: prompt user when adding old positions

### Cash Positions
- Balance can never go negative — warning shown if attempted
- All transactions are append-only records (never edit in place)
- Buy deduction: auto-prompt "Deduct from cash?" with position picker
- Sell proceeds: auto-prompt "Add to cash?" with position picker
- Cash drag calculation: opportunity cost vs portfolio YTD return (informational only)
- Interest logged monthly as `CashTransaction` type `interestEarned`

### Treasury Positions
- Maturity prompt: "T-Bill matured — add $X to cash?" with options
- I-Bond composite rate formula: `fixed + (2 × inflation) + (fixed × inflation)`
- I-Bond rate reminder: every May and November
- TIPS phantom income flagged prominently (inflation adjustment = taxable income)
- Accrued interest calculation: `(couponRate × faceValue) × (daysSinceLastCoupon / 365)`
- T-Bill BEY formula: `(discount / purchasePrice) × (365 / daysToMaturity)`

### Lot Selection — Sell Flow
1. User taps Sell on a position
2. Choose lot method: Specific Lot / FIFO / LIFO / Highest Cost / Lowest Cost
3. If Specific Lot: lot picker shows all open lots with LT/ST badge, tax estimate, advisory
4. Quantity slider for partial lot sells
5. Partial sells: remaining shares keep original purchase date and cost basis
6. Intentional ST sell when LT available: non-blocking advisory (not a blocker)
7. Wash sale detection: warn if same symbol purchased within 30 days
8. 30-second undo toast after confirmation

### Import
Supported formats: CSV, JSON, XLSX
Full transaction history import (not just holdings/cost basis)
Column mapping UI for non-standard CSV headers
Auto-detection: asset type, date formats, action synonyms
Validation: errors block import, warnings allow with acknowledgement
Conflict resolution: Merge / Replace / Import as new
60-second undo window with full rollback
Template CSV available for download from import screen

### News & Earnings Push Notifications

**Earnings:**
- 7 days before: "AAPL reports earnings in 7 days (AMC)"
- 1 day before: "AAPL reports tomorrow after market close"
- Day of (8AM): "AAPL reports today"
- Post-earnings: "AAPL beat EPS by X% — tap to see details"
- Rescheduled if date shifts (weekly re-check)

**Breaking news:**
- Background fetch every 5 minutes while active
- Only for held symbols
- Only if article < 60 minutes old
- Max 3 breaking news notifications per day
- Sentiment filter: all news or negative only (user configurable)

**Options expiry:**
- 14 days: early warning
- 7 days: urgent
- 3 days: critical
- On expiry: expired flag in Holdings list (greyed + badge)
- Expired options: NOT auto-deleted — user reviews before removing

**Holding period:**
- Configurable threshold (default 30 days before LT)
- Alert: "[Symbol] Lot [N] qualifies for Long-Term rate in 30 days"
- Alert: "[Symbol] Lot [N] is now Long-Term"

**Treasury:**
- 30 days before maturity (configurable)
- Day of maturity: prompt to add proceeds to cash
- Day of coupon: "T-Note coupon of $X due — mark received?"
- I-Bond redeemable (1yr anniversary)
- I-Bond penalty-free (5yr anniversary)
- I-Bond rate update (May and November)

---

## Industry Dependency Map

Data source: Bundled JSON (`industry-graph.json`) + remote quarterly update
Coverage: S&P 500 + major crypto ecosystems

Per stock shows:
- Upstream: companies that supply to this stock
- Downstream: companies that depend on this stock
- Downstream sector exposure: bar chart by %

Portfolio-level: Concentration risk warnings on Allocations screen
e.g. "High exposure: Semiconductor supply chain — NVDA + AMD + TSM share upstream dependency on ASML. Affects 34% of portfolio."

---

## Privacy & Security

- No account creation — Apple ID / iCloud IS the identity
- No third-party servers see portfolio data
- Only Finnhub/CoinGecko receive ticker symbols (not quantities or cost basis)
- CloudKit private container — Apple cannot read encrypted data
- Face ID / Touch ID lock on app open
- Configurable lock delay: Immediate / 30s / 1min / 5min
- App switcher blur: sensitive data hidden in multitasking view
- Finnhub API key stored in iOS Keychain only

---

## No Account Creation

The app deliberately has no sign-up, login, or account system.
Identity = Apple ID (iCloud).
Data = iCloud private CloudKit container.
Multi-device sync = automatic via NSPersistentCloudKitContainer.
Data recovery = reinstall app, sign into same Apple ID, data restores.
