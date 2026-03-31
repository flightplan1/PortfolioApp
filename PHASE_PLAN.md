# Phase Plan

## Current Status: Pre-Phase 1 — Ready to Build

All planning is complete. All 8 priority fixes are resolved.
Start with Phase 1 immediately.

---

## Phase 1 — Core Foundation
**Scope:**
- Xcode project setup (SwiftUI, iOS 16+, CloudKit capability)
- CoreData schema v1: Holding, Lot, Transaction, BaseFinancialRecord
- NSPersistentCloudKitContainer setup with lightweight migration
- iCloud availability check + local-only fallback banner
- PriceService.swift: Finnhub (stocks/ETFs) + CoinGecko (crypto) with batching
- APIKeyManager.swift: Keychain storage for Finnhub key
- NetworkMonitor.swift: offline detection
- DecimalExtensions.swift: safe financial math
- DateExtensions.swift: 366-day LT logic, trade date handling
- AppLockManager.swift: Face ID / Touch ID
- Holdings CRUD: add, edit, delete (soft), list
- Basic Holdings list view (no price data yet)

**Deliverable:** App launches, persists holdings to CloudKit, fetches live prices.

---

## Phase 1b — Position Import
**Scope:**
- ImportService.swift: atomic import with 60-second undo snapshot
- CSVParser.swift: column auto-detection, synonym mapping, date format detection
- JSONImporter.swift: structured JSON format
- XLSXImporter.swift: first-sheet reader
- Import UX: file picker → column mapping → preview/validation → conflict resolution → result
- Template CSV bundled in Resources/
- ImportSession CoreData entity
- Validation rules: errors vs warnings
- Split detection during import (individual confirmation prompts)

**Deliverable:** Full transaction history importable from CSV/JSON/XLSX.

---

## Phase 2 — Dashboard
**Scope:**
- Total portfolio value with hide/show toggle (blur, not hide)
- Unrealized P&L (all-time)
- Today's change ($ and %)
- Portfolio allocation donut chart (Swift Charts)
- Cash available to deploy summary
- Today's top movers
- Cash drag calculation
- 2026 Realized P&L compact strip
- Holdings period summary (LT/ST breakdown)
- Market hours awareness (suppress LIVE indicator when closed)
- Stale price indicator (> 15 min)

---

## Phase 3 — Allocations Screen
**Scope:**
- Donut chart by asset type (Stock/ETF/Crypto/Options/Cash/Treasury)
- Donut chart by sector
- List by individual holding (% of portfolio)
- Treasury allocation slice
- Sector concentration risk warnings (from industry-graph.json)
- Cash slice (never lumped into "other")

---

## Phase 4 — Historical P&L Chart
**Scope:**
- Line chart of portfolio value over time (Swift Charts)
- Time range selector: 1W / 1M / 3M / 1Y / All
- Reconstructed from Transactions + price history (Finnhub historical OHLC)
- Realized vs unrealized P&L overlay

---

## Phase 5 — Options Enhancements
**Scope:**
- Expiry tracking with alert scheduling (UNUserNotificationCenter)
- Alert tiers: 14d / 7d / 3d / expired
- Expired options: greyed + badge in Holdings list (not auto-deleted)
- Section 1256 auto-detection (SPX, SPXW, NDX, NDXP, RUT, VIX, XSP)
- Bank fee per contract (override app default)
- Options ×100 multiplier enforced throughout
- OCC adjustment warning on split stocks

---

## Phase 6 — Tax Module
**Scope:**
- TaxEngine.swift: full stacked bracket calculation
- Federal brackets (ST + LT + NIIT) from tax-rates.json
- State brackets/rates from tax-rates.json
- City brackets/rates from tax-rates.json
- LT/ST determination using 366-day rule
- Section 1256 60/40 calculation
- Simulate Sale sheet with full tax breakdown
- Lot-level tax estimates in Lots tab
- Tax year summary in P&L Realized tab
- Wash sale detection
- AMT warning for gains > $100k
- Onboarding tax profile (3-step: filing status → income → location)
- Tax profile incomplete banner (non-dismissible)
- All disclaimer tiers implemented

---

## Phase 7 — Remote JSON Config
**Scope:**
- TaxRatesLoader.swift: fetch remote JSON, compare version, cache locally
- industry-graph.json loader
- Settings UI: remote URL config, version display
- New tax year detection: persistent banner if rates may be outdated
- Offline fallback: "Using 2026 rates (offline)" label
- Remote fetch: on launch + monthly

---

## Phase 8 — Transaction Page & Lot System
**Scope:**
- Full lot tracking per position
- LT/ST badges on each lot
- Progress bar to LT (showing exact qualifying date + "X / 366 days")
- Gold advisory for lots within 60 days of LT (with est. tax saving)
- Lot picker UI: Specific Lot / FIFO / LIFO / Highest Cost / Lowest Cost
- Partial lot sells (remaining shares preserve original purchase date)
- Sell sheet with quantity slider + full tax breakdown
- Wash sale warning
- 30-second undo toast
- Transaction history with edit / soft delete
- Realized transaction recording (all 4 tax layers stored at time of sale)

---

## Phase 9 — Dividend Tracking
**Scope:**
- DividendEvent CoreData entity
- DRIP toggle per holding
- Auto-lot creation on DRIP confirmation
- Manual dividend entry
- Dividend history view in position detail
- DRIP → new lot linking (lotSource = .drip)
- Dividend tax in year summary
- Projected annual dividend income
- Yield per position display
- Ex-dividend date alerts (2 days before)
- Dividend received alerts

---

## Phase 10 — Stock Splits
**Scope:**
- SplitEvent + SplitSnapshot CoreData entities
- Finnhub split detection on launch (daily check)
- Confirmation UI before any split application
- Atomic lot adjustment (all lots updated in one CoreData transaction)
- Original quantity/basis preserved, split-adjusted fields updated
- SplitSnapshot for 24-hour revert
- Reverse split: fractional cash-out option
- Pre-app historical split entry
- Split history in position detail Overview tab
- Options on split stocks: freeze P&L + OCC warning

---

## Phase 11 — Cash Positions
**Scope:**
- CashPosition + CashTransaction CoreData entities
- USD cash and Money Market Fund types
- APY tracking (manual entry; MMF can use ticker for auto-fetch)
- Balance append-only (never edit in place)
- Auto-deduct on buy: prompt "Deduct from cash?" with position picker
- Auto-add on sell: prompt "Add to cash?" with position picker
- Cash drag calculation (opportunity cost vs portfolio return)
- Interest earned logging (monthly CashTransaction)
- Cash in allocation charts
- Cash in dashboard (available to deploy)
- Cash balance never-negative enforcement

---

## Phase 12 — Treasury Positions
**Scope:**
- TreasuryPosition + CouponPayment CoreData entities
- All 5 types: T-Bill, T-Note, T-Bond, TIPS, I-Bond
- Add treasury form with type-specific fields
- YTM auto-calculation for T-Bills (BEY formula)
- Accrued interest calculation
- Days to maturity display + alert scheduling
- Coupon payment tracking (mark received → prompt cash)
- Maturity event: prompt to add proceeds to cash
- TIPS inflation adjustment tracking + phantom income warning
- I-Bond composite rate formula + 1yr lockup + 5yr penalty tracking
- I-Bond rate update reminder (May + November)
- I-Bond $10k/yr purchase limit warning
- Treasury in allocation charts
- Treasury in dashboard
- Treasury state/city tax exemption in tax calculations

---

## Phase 13 — News, Earnings & Notifications
**Scope:**
- NewsService.swift: Finnhub REST (not WebSocket) polling every 30 min
- EarningsService.swift: Finnhub earnings calendar, weekly refresh
- CoinGecko news for crypto holdings
- In-app news feed with sentiment dots
- Earnings calendar view
- Background fetch for breaking news (BGAppRefreshTask)
- All alert types (earnings, breaking news, options expiry, LT threshold, treasury maturity, coupon)
- Per-symbol notification toggles in Settings
- Max 3 breaking news/day throttle
- Sentiment filter: all / negative only
- Earnings date change detection (weekly re-check, reschedule notifications)

---

## Phase 14 — Industry Dependency Map
**Scope:**
- industry-graph.json loader (bundled + remote quarterly)
- Per-position Industry tab in position detail
- Upstream / downstream company lists with "In Portfolio" badges
- Downstream sector exposure bar chart
- Portfolio-level concentration risk warnings on Allocations screen

---

## Phase 15 — Polish & Export
**Scope:**
- CSV export (same format as import — full round-trip)
- Export header: full disclaimer as comment rows
- iOS home screen widget (portfolio value + daily change)
- Watchlist (non-held symbols for news/earnings tracking)
- Per-symbol note field on positions
- Accessibility: Dynamic Type, VoiceOver labels, 44pt tap targets
- App Store preparation

---

## Deferred / Known Gaps (Post-Phase 15)

- Pre/post market prices
- S&P 500 benchmark comparison
- Spin-off / special dividend handling
- Foreign currency holdings
- AMT calculation (warned but not calculated)
- Treasury secondary market accrued interest on purchase
- Multi-year tax-loss harvesting optimization
- Carry-forward loss tracking across years
