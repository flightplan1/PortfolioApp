# Architecture

## Storage Layers

### Layer 1 — CloudKit (via CoreData) — User's iCloud Private Container
Synced across all user's devices. Only the user's Apple ID can access this.

**Entities synced:**
- Holdings
- Lots
- Transactions
- DividendEvents
- SplitEvents
- CouponPayments (treasuries)
- TreasuryPositions
- CashPositions
- CashTransactions
- RealizedTransactions
- ImportSessions (metadata only)

### Layer 2 — CoreData Local Only (not CloudKit)
Ephemeral / cache data. Re-fetched on launch.

**Entities local only:**
- PriceSnapshot (30 min cache)
- NewsArticle (30 min cache)
- EarningsCache (7 day cache)
- ImportSnapshot (pre-import rollback, max 60 seconds then discarded)

### Layer 3 — iCloud Key-Value Store (NSUbiquitousKeyValueStore)
Small settings data synced across devices instantly.

**Keys stored:**
- `filingStatus` — single / mfj / hoh
- `annualIncome` — Int
- `state` — String
- `city` — String
- `residency` — resident / nonresident
- `defaultLotMethod` — fifo / lifo / highestCost / specificLot
- `defaultBankFee` — Decimal
- `biometricLockEnabled` — Bool
- `lockAfterSeconds` — Int
- `dripDefault` — Bool
- `taxRatesVersion` — String
- `industryGraphVersion` — String
- `onboardingTaxAcknowledged` — Bool
- `ltAlertThresholdDays` — Int (default 30)
- `optionExpiryAlertDays` — [Int] (default [14, 7, 3])
- `earningsAlertEnabled` — Bool
- `breakingNewsAlertEnabled` — Bool

### Layer 4 — Bundled Resources
Static files shipped with the app, updated via remote fetch.

- `tax-rates.json` — federal/state/city brackets (v2026.1)
- `industry-graph.json` — upstream/downstream dependency map (v2026.Q1)

Remote fetch: user's private GitHub raw URL, checked on launch, cached locally.

---

## CloudKit Configuration

```swift
// PersistenceController.swift
let container = NSPersistentCloudKitContainer(name: "PortfolioApp")

let description = container.persistentStoreDescriptions.first!
description.setOption(true as NSNumber,
    forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber,
    forKey: NSInferMappingModelAutomaticallyOption)

// CloudKit container identifier
// com.yourname.PortfolioApp — set in Xcode capabilities
```

## CoreData Schema Versioning

**Rule: Create a new model version for every schema change.**

```
PortfolioApp.xcdatamodeld/
  PortfolioApp v1.xcdatamodel   ← Phase 1
  PortfolioApp v2.xcdatamodel   ← Phase 2 (if schema changes)
  ...
```

Lightweight migration handles: adding optional attributes, adding entities.
Custom mapping model required for: renames, type changes, removals.

**Test migration on device with prior version data before every release.**

---

## CloudKit Conflict Resolution

Financial records (Lot, Transaction) → **always surface to user, never auto-resolve.**
Settings and non-financial records → last-write-wins by timestamp.

```swift
func resolveConflict(local: BaseFinancialRecord, remote: BaseFinancialRecord) -> ConflictResolution {
    if local is Lot || local is Transaction {
        return .requireUserResolution(local: local, remote: remote)
    }
    return local.lastModifiedAt > remote.lastModifiedAt ? .keepLocal : .keepRemote
}
```

All financial entities inherit `BaseFinancialRecord` which includes:
- `ckRecordID: String?`
- `ckRecordChangeTag: String?`
- `lastModifiedDevice: String?`
- `lastModifiedAt: Date?`

---

## API Architecture

### Finnhub (Primary — Stocks, ETFs, News, Earnings, Dividends, Splits)
- Base URL: `https://finnhub.io/api/v1`
- Auth: API key in request header `X-Finnhub-Token`
- API key stored in iOS Keychain (never hardcoded)
- Rate limit: 60 calls/min, 30 calls/sec
- Strategy: batch all symbols in one scheduled fetch, not per-symbol

**Endpoints used:**
```
GET /quote?symbol=NVDA                    — real-time price
GET /stock/candle                         — historical OHLC
GET /company-news?symbol=NVDA             — news (REST, not WebSocket)
GET /calendar/earnings                    — earnings calendar
GET /stock/dividend?symbol=NVDA           — dividend history
GET /stock/split?symbol=NVDA             — split history
```

**Note:** Finnhub WebSocket is unreliable on free tier — use REST polling only.

### CoinGecko (Crypto Prices)
- Base URL: `https://api.coingecko.com/api/v3`
- Auth: None required for free tier
- Rate limit: 30 calls/min
- Strategy: batch crypto symbols in one call using `/simple/price?ids=bitcoin,ethereum&vs_currencies=usd`

### Price Refresh Strategy
- On app foreground: fetch all held symbols
- While active: refresh every 60 seconds
- Market hours awareness: suppress "LIVE" indicator when markets closed
- Stale data threshold: show timestamp warning if price > 15 minutes old
- Offline: use last cached PriceSnapshot with "Last updated X min ago" label

### API Key Storage
```swift
// APIKeyManager.swift — Keychain only
class APIKeyManager {
    static func saveFinnhubKey(_ key: String) throws { ... }
    static func getFinnhubKey() throws -> String { ... }
    // Never UserDefaults, never hardcoded
}
```

---

## Security Architecture

### Biometric Lock
```swift
// AppLockManager.swift
class AppLockManager: ObservableObject {
    @Published var isUnlocked = false
    @AppStorage("biometricLockEnabled") var lockEnabled = true

    func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock your portfolio"
        ) { success, _ in
            DispatchQueue.main.async { self.isUnlocked = success }
        }
    }

    func lockOnBackground() { isUnlocked = false }
}
```

Lock triggers: on app background (after configurable delay: immediate/30s/1min/5min)
App switcher: blur overlay added on `sceneWillResignActive`, removed on `sceneDidBecomeActive`

---

## Financial Math Rules

### Use Decimal, Never Double
All financial calculations use `Decimal` type — never `Float` or `Double`.
`Double` has floating point precision errors that compound in financial math.

```swift
// DecimalExtensions.swift
extension Decimal {
    func rounded(to places: Int) -> Decimal {
        var result = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, places, .bankers)
        return rounded
    }
}
```

### Holding Period — LT Determination
```swift
// DateExtensions.swift
extension Date {
    func qualifiesForLongTerm(purchaseDate: Date) -> Bool {
        let calendar = Calendar.current
        let oneYearAfterPurchase = calendar.date(
            byAdding: .year, value: 1, to: purchaseDate
        )!
        // IRS: must be STRICTLY MORE THAN 12 months
        // Sale date must be strictly after the 1-year anniversary
        return self > oneYearAfterPurchase
    }

    var daysToLongTerm: Int? {
        // Returns nil if already LT, else days remaining
        ...
    }
}
```

### Options Multiplier
```swift
struct OptionsCalculator {
    static let sharesPerContract = 100

    static func totalCost(contracts: Int, premiumPerShare: Decimal, fee: Decimal) -> Decimal {
        return (Decimal(contracts) * premiumPerShare * Decimal(sharesPerContract)) + fee
    }

    static func unrealizedPnL(contracts: Int, currentPrice: Decimal, avgCostPerShare: Decimal) -> Decimal {
        return (currentPrice - avgCostPerShare) * Decimal(contracts) * Decimal(sharesPerContract)
    }
}
```

### Transaction Safety — Soft Delete
```swift
// Never hard delete financial records
transaction.isDeleted = true
transaction.deletedAt = Date()
transaction.deletionReason = .userDeleted
// Hard purge after 30 days (CloudKit sync window)
```

---

## Undo Architecture

| Action | Undo Window | Method |
|---|---|---|
| Single transaction (buy/sell/dividend) | 30 seconds | Soft delete + toast |
| Import | 60 seconds | Full CoreData snapshot rollback |
| Split application | 24 hours | SplitSnapshot restore |
| Manual edit | Indefinite | Edit/delete from transaction history |

---

## iCloud Availability Handling

```swift
// On app launch
switch FileManager.default.ubiquityIdentityToken {
case nil:
    // iCloud not available — local only mode
    showBanner("iCloud is off — data won't sync. Enable in Settings.")
default:
    // iCloud available — full sync
}
```
