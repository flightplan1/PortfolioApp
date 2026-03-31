# Priority Fixes — Resolved Before Phase 1

All 8 fixes below were identified in a pre-Phase 1 gap review and are fully resolved.
Every fix has a concrete implementation pattern. Follow these exactly — do not revert.

---

## Fix 1 — 366-Day LT Threshold (not 365)

**Problem:** Using 365 days as the LT threshold is technically wrong.
IRS rule: asset must be held **more than 12 months** — i.e. sale date must be strictly after the 1-year anniversary.

**Implementation:**
```swift
// DateExtensions.swift
func isLongTerm(purchaseDate: Date, saleDate: Date) -> Bool {
    let calendar = Calendar.current
    let oneYearAfterPurchase = calendar.date(
        byAdding: .year, value: 1, to: purchaseDate
    )!
    return saleDate > oneYearAfterPurchase  // STRICTLY after
}
```

**UI:** Progress bar shows "X / 366 days". Qualifying date shown as exact date, not day count.
**Never use 365 as a threshold anywhere in the codebase.**

---

## Fix 2 — Bracket Stacking for Tax Calculation

**Problem:** Applying the marginal rate to the entire capital gain is wrong.
A $50k short-term gain does not all get taxed at 22%.

**Implementation:**
```swift
// TaxEngine.swift
func stackedBracketTax(
    existingIncome: Decimal,    // user's salary/other income
    additionalIncome: Decimal,  // the capital gain being added
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

**NIIT:** Applies to lesser of NII OR excess MAGI above threshold — not flat 3.8% on all gains.
**State:** Same stacking logic applies to graduated state taxes (CA, NY, NJ etc.)

---

## Fix 3 — Options ×100 Multiplier Consistency

**Problem:** Options P&L and tax calculations must always apply the 100-shares-per-contract multiplier.
1 contract ≠ 1 share. Missing this multiplier causes 100× errors silently.

**Implementation:**
```swift
// OptionsCalculator.swift
struct OptionsCalculator {
    static let sharesPerContract = 100

    static func totalCost(contracts: Int, premiumPerShare: Decimal, fee: Decimal) -> Decimal {
        (Decimal(contracts) * premiumPerShare * Decimal(sharesPerContract)) + fee
    }

    static func unrealizedPnL(contracts: Int, currentPrice: Decimal, avgCostPerShare: Decimal) -> Decimal {
        (currentPrice - avgCostPerShare) * Decimal(contracts) * Decimal(sharesPerContract)
    }
}
```

**UI:** Always display "2 contracts × 100 shares = 200 share equivalent" — never just "2 × $45 = $90".
**All options calculations** must go through OptionsCalculator — never inline math.

---

## Fix 4 — Undo / Soft Delete for Transactions

**Problem:** No way to recover from accidental buy/sell entries.

**Implementation:**
- Never hard delete financial records — always soft delete
- 30-second undo toast for single transactions
- 60-second undo snapshot for imports
- All transactions remain editable from transaction history indefinitely

```swift
// Soft delete pattern
transaction.isDeleted = true
transaction.deletedAt = Date()
transaction.deletionReason = .userDeleted
// Hard purge after 30 days (CloudKit sync window)
```

**30-second undo toast:** Shows countdown ring. Undo reverses the transaction completely.
**Import undo:** Full CoreData snapshot rollback within 60 seconds.

---

## Fix 5 — Face ID / Biometric Lock

**Problem:** App contains sensitive financial data but has no access protection.

**Implementation:**
```swift
// AppLockManager.swift
import LocalAuthentication

class AppLockManager: ObservableObject {
    @Published var isUnlocked = false

    func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock your portfolio"
        ) { success, _ in
            DispatchQueue.main.async { self.isUnlocked = success }
        }
    }
}
```

**App switcher blur:**
```swift
func sceneWillResignActive(_ scene: UIScene) {
    window?.addBlurOverlay()
}
func sceneDidBecomeActive(_ scene: UIScene) {
    window?.removeBlurOverlay()
}
```

**Lock delay options:** Immediate / 30 seconds / 1 minute / 5 minutes (user configurable)
**Fallback:** Passcode if no biometrics enrolled.

---

## Fix 6 — CoreData Migration Strategy

**Problem:** Schema changes in later phases will crash existing installs without migration.

**Implementation — from Phase 1:**
```swift
// PersistenceController.swift
let description = container.persistentStoreDescriptions.first!
description.setOption(true as NSNumber,
    forKey: NSMigratePersistentStoresAutomaticallyOption)
description.setOption(true as NSNumber,
    forKey: NSInferMappingModelAutomaticallyOption)
```

**Version naming convention:**
```
PortfolioApp.xcdatamodeld/
  PortfolioApp v1.xcdatamodel   ← Phase 1
  PortfolioApp v2.xcdatamodel   ← Phase 2 (if schema changes needed)
  ...
```

**Rules:**
- Adding optional attributes → lightweight migration (automatic)
- Adding new entities → lightweight migration (automatic)
- Renaming attributes → custom mapping model required
- Removing attributes → custom mapping model required
- Changing attribute type → custom mapping model + data transform

**Required:** Test migration on device with prior version data before every phase that changes schema.

---

## Fix 7 — CloudKit Conflict Resolution

**Problem:** "Last write wins" is dangerous for financial records. Simultaneous edits on two devices could corrupt lot quantities or cost basis.

**Implementation:**
```swift
// All financial entities inherit BaseFinancialRecord
class BaseFinancialRecord: NSManagedObject {
    @NSManaged var ckRecordID: String?
    @NSManaged var ckRecordChangeTag: String?
    @NSManaged var lastModifiedDevice: String?
    @NSManaged var lastModifiedAt: Date?
}

func resolveConflict(local: BaseFinancialRecord, remote: BaseFinancialRecord) -> ConflictResolution {
    // Financial records: ALWAYS surface to user
    if local is Lot || local is Transaction {
        return .requireUserResolution(local: local, remote: remote)
    }
    // Non-financial: latest wins
    return (local.lastModifiedAt ?? .distantPast) > (remote.lastModifiedAt ?? .distantPast)
        ? .keepLocal : .keepRemote
}
```

**Conflict UI:** Shows both versions side by side, lets user choose. Never silently resolves financial data conflicts.

---

## Fix 8 — Trade Date vs Settlement Date

**Problem:** IRS uses trade date (T+0) for holding period, not settlement date (T+1 or T+2).
Using settlement date could cause incorrect LT/ST classification.

**Implementation:**
```swift
struct Transaction {
    let tradeDate: Date        // Required — IRS holding period
    let settlementDate: Date?  // Optional — for cash flow tracking only

    var holdingPeriodDays: Int {
        Calendar.current.dateComponents([.day], from: tradeDate, to: Date()).day ?? 0
    }
}
```

**UI label:** "Trade Date (for tax purposes)" — not just "Date"
**Settlement date:** Auto-calculated as T+1, shown as informational only, never used for tax calculations.

---

## Additional Accuracy Fixes (Identified in Gap Review)

### Default Income = $70,000
When tax profile incomplete, all estimates use:
- Filing status: Single
- Annual income: $70,000 (places user in 22% federal bracket — conservative realistic default)
- No state, no city

### Crypto Wash Sale Warning
Wash sale rule does not currently apply to crypto (as of 2026).
But show a persistent note: "Crypto wash sale rules may change with future legislation."

### TIPS Phantom Income
TIPS inflation adjustment to principal is taxable as ordinary income in the year it accrues,
even though it's not received as cash. Flag prominently in TIPS position detail —
not just a footnote.

### I-Bond Issue Date vs Purchase Date
I-Bond lockup period uses **first day of purchase month** (TreasuryDirect convention),
not the exact purchase date. Match this behavior in date calculations.

### MMF Not FDIC Insured
Show note in MMF position: "Money market funds are not FDIC insured and may lose value in extreme market conditions."
