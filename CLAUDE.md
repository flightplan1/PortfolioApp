# PortfolioApp — Claude Code Project Context

This file provides full context for continuing development of PortfolioApp in Claude Code.
All planning, design decisions, architecture, and fixes were established in a prior Claude.ai session.
**Do not re-litigate decisions already made — follow this document as the source of truth.**

---

## Project Overview

A personal iOS investment tracking app built in **SwiftUI / Swift**, synced via **CloudKit**.
No backend. No account creation. No third-party servers storing user data.
All data lives in the user's private iCloud container.

**Target platform:** iOS 16+ (required for Swift Charts)
**Language:** Swift 5.9+
**UI Framework:** SwiftUI
**Persistence:** CoreData + NSPersistentCloudKitContainer
**Charts:** Swift Charts (native)
**Notifications:** UNUserNotificationCenter (local only)
**Biometric lock:** LocalAuthentication framework

---

## Documentation Map

| File | Contents |
|---|---|
| `CLAUDE.md` | This file — master context and quick reference |
| `docs/ARCHITECTURE.md` | Full technical architecture, data models, API strategy |
| `docs/FEATURES.md` | Complete feature list, all modules, UX flows |
| `docs/TAX_MODULE.md` | Tax calculation rules, bracket stacking, disclaimers |
| `docs/PHASE_PLAN.md` | Full phased build plan with scope per phase |
| `docs/FIXES.md` | 8 priority fixes agreed before Phase 1 |
| `docs/DATA_MODELS.md` | Every CoreData entity and field |
| `docs/API_STRATEGY.md` | Finnhub + CoinGecko strategy, why Yahoo Finance was rejected |
| `docs/IMPORT_FORMAT.md` | CSV/JSON/XLSX import spec and column mapping |
| `docs/UI_REFERENCE.md` | Screen architecture, mockup descriptions, design tokens |
| `docs/DISCLAIMERS.md` | Exact disclaimer text, placement rules, tiering system |

---

## Critical Rules — Read Before Writing Any Code

1. **LT threshold is 366 days** (more than 12 months per IRS) — never 365
2. **Tax brackets must stack** — never apply marginal rate to full gain
3. **Options always use ×100 multiplier** — 1 contract = 100 shares
4. **Trade date** (not settlement date) determines holding period
5. **All tax figures show `~` tilde prefix** and "estimated only" disclaimer
6. **No sudo ever** — iOS dev never needs system-level access
7. **All files stay inside `~/Developer/PortfolioApp`**
8. **CoreData schema versioned from day 1** — PortfolioApp v1, v2, v3...
9. **CloudKit conflicts on financial records → always surface to user**, never auto-resolve
10. **Yahoo Finance is banned** — use Finnhub (stocks/ETFs) + CoinGecko (crypto)

---

## Current Status

**Phase:** Pre-Phase 1 — all planning complete, ready to build
**Next action:** Create Xcode project, CoreData schema, CloudKit setup, PriceService

### What exists already
- Full feature design across all modules
- CoreData entity definitions (see `docs/DATA_MODELS.md`)
- React/JSX UI mockups (reference only — not Swift code):
  - `app-mockup.jsx` — full 5-tab app
  - `position-detail.jsx` — position detail with sell sheet
  - `onboarding.jsx` — tax profile onboarding
  - `pnl-screen.jsx` — P&L screen
- `tax-rates.json` — full federal/state/city tax bracket JSON (v2026.1)

### What does not exist yet
- Any Swift/SwiftUI code
- Xcode project
- CoreData schema file

---

## Tech Stack — Confirmed Decisions

| Layer | Choice | Notes |
|---|---|---|
| UI | SwiftUI | iOS 16+ |
| Persistence | CoreData | NSPersistentCloudKitContainer |
| Cloud sync | CloudKit | Private container — user's iCloud only |
| Settings sync | NSUbiquitousKeyValueStore | iCloud KV for tax profile, preferences |
| Price data — stocks/ETFs | Finnhub REST API | 60 calls/min free tier |
| Price data — crypto | CoinGecko REST API | Better crypto coverage than Finnhub |
| Price data — options | Finnhub (limited) + manual fallback | Free tier limited for options |
| News + sentiment | Finnhub REST | Not WebSocket — WebSocket is unreliable |
| Earnings calendar | Finnhub REST | Strong on free tier |
| Dividends history | Finnhub REST | 30yr history available |
| Stock splits | Finnhub REST | Split-adjusted prices built in |
| MMF yield | Manual entry only | No reliable free API |
| Charts | Swift Charts | Native iOS 16+ |
| API key storage | iOS Keychain | Never hardcoded, never UserDefaults |
| Biometric lock | LocalAuthentication | Face ID / Touch ID |
| Local notifications | UNUserNotificationCenter | No push server needed |

**Rejected:** Yahoo Finance — unofficial scraper, ToS violation risk, breaks silently, not suitable for production.

---

## Asset Types Supported

1. **Stocks** — US equities
2. **ETFs** — treated same as stocks for price/P&L
3. **Crypto** — BTC, ETH, SOL etc. via CoinGecko
4. **Options** — with ×100 multiplier, Section 1256 support, expiry tracking
5. **Cash** — USD cash positions with APY tracking
6. **Money Market Funds** — near-cash, 7-day yield, ticker-based
7. **US Treasuries** — T-Bills, T-Notes, T-Bonds, TIPS, I-Bonds

---

## Project Folder Structure (Target)

```
~/Developer/PortfolioApp/
├── PortfolioApp.xcodeproj
├── PortfolioApp/
│   ├── App/
│   │   ├── PortfolioAppApp.swift
│   │   └── PersistenceController.swift
│   ├── Models/
│   │   ├── PortfolioApp.xcdatamodeld/
│   │   │   └── PortfolioApp v1.xcdatamodel
│   │   └── Entities/
│   │       ├── Holding+CoreData.swift
│   │       ├── Lot+CoreData.swift
│   │       ├── Transaction+CoreData.swift
│   │       ├── CashPosition+CoreData.swift
│   │       ├── TreasuryPosition+CoreData.swift
│   │       ├── DividendEvent+CoreData.swift
│   │       ├── SplitEvent+CoreData.swift
│   │       └── CouponPayment+CoreData.swift
│   ├── Services/
│   │   ├── PriceService.swift
│   │   ├── NewsService.swift
│   │   ├── EarningsService.swift
│   │   ├── APIKeyManager.swift
│   │   └── NetworkMonitor.swift
│   ├── Tax/
│   │   ├── TaxEngine.swift
│   │   ├── TaxRatesLoader.swift
│   │   └── TaxProfile.swift
│   ├── Import/
│   │   ├── ImportService.swift
│   │   ├── CSVParser.swift
│   │   ├── JSONImporter.swift
│   │   └── XLSXImporter.swift
│   ├── Views/
│   │   ├── Dashboard/
│   │   ├── Holdings/
│   │   ├── PnL/
│   │   ├── News/
│   │   ├── Settings/
│   │   └── Onboarding/
│   ├── Utilities/
│   │   ├── DecimalExtensions.swift
│   │   ├── DateExtensions.swift
│   │   └── AppLockManager.swift
│   └── Resources/
│       ├── tax-rates.json
│       └── industry-graph.json
```

---

## Key Contacts / References

- Tax rates JSON: `Resources/tax-rates.json` (v2026.1, updated Jan 15 2026)
- Industry graph JSON: `Resources/industry-graph.json` (v2026.Q1)
- Remote tax rates hosted on: user's private GitHub repo (Option C+D strategy)
- Finnhub API docs: https://finnhub.io/docs/api
- CoinGecko API docs: https://www.coingecko.com/api/documentation
