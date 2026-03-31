# Import Format Specification

## Overview

Supports: CSV, JSON, XLSX
Imports: Full transaction history (not just holdings/cost basis)
All transaction history preserves lot-level detail for LT/ST tracking and tax calculations.

---

## CSV Format

### Required Columns
| Column | Type | Notes |
|---|---|---|
| Symbol | String | Ticker e.g. "NVDA", "BTC" |
| TradeDate | Date | YYYY-MM-DD preferred; many formats supported |
| Action | String | See Action values below |
| Quantity | Decimal | Must be > 0 |
| PricePerShare | Decimal | Must be ≥ 0 |

### Optional Columns
| Column | Type | Notes |
|---|---|---|
| CostBasis | Decimal | Computed as Qty × Price if missing |
| AssetType | String | Auto-detected if missing |
| Sector | String | Left blank if missing |
| Fee | Decimal | Bank/broker commission |
| Notes | String | Free text |

### Supported Action Values
```
BUY          PURCHASE       BOUGHT
SELL         SALE           SOLD
DIVIDEND     DIV            INCOME
DRIP         REINVESTMENT   REINVEST
SPLIT                       (ratio in Notes e.g. "10:1")
TRANSFER_IN  TRANSFER_OUT
```

### Example CSV
```csv
# PortfolioApp Import Format v1
# Required: Symbol, TradeDate, Action, Quantity, PricePerShare
# Optional: CostBasis, AssetType, Sector, Fee, Notes
Symbol,TradeDate,Action,Quantity,PricePerShare,CostBasis,AssetType,Sector,Fee,Notes
NVDA,2024-03-03,BUY,100,875.00,87500.00,Stock,Semiconductors,9.99,
NVDA,2025-02-14,BUY,50,920.00,46000.00,Stock,Semiconductors,9.99,
NVDA,2026-01-10,BUY,25,115.00,2875.00,Stock,Semiconductors,9.99,
NVDA,2024-06-10,SPLIT,,,,,,,10:1 forward split
AAPL,2023-06-12,BUY,200,178.20,35640.00,Stock,Consumer Tech,9.99,
BTC,2024-11-05,BUY,0.5,42000.00,21000.00,Crypto,Crypto,0,
NVDA,2026-03-10,SELL,40,932.00,,Stock,,,
AAPL,2026-03-14,DRIP,,,,Stock,Consumer Tech,,Quarterly dividend $48.00 reinvested
```

---

## JSON Format

```json
{
  "importVersion": "1.0",
  "exportedAt": "2026-03-19",
  "transactions": [
    {
      "symbol": "NVDA",
      "tradeDate": "2024-03-03",
      "action": "BUY",
      "quantity": 100,
      "pricePerShare": 875.00,
      "costBasis": 87500.00,
      "assetType": "Stock",
      "sector": "Semiconductors",
      "fee": 9.99,
      "notes": ""
    },
    {
      "symbol": "NVDA",
      "tradeDate": "2024-06-10",
      "action": "SPLIT",
      "quantity": null,
      "pricePerShare": null,
      "notes": "10:1 forward split",
      "splitRatio": { "numerator": 10, "denominator": 1 }
    }
  ]
}
```

---

## XLSX Format

- First sheet only
- Header row required
- Same column names as CSV
- Numeric columns must be actual numbers (not text-formatted)

---

## Auto-Detection

### Asset Type Detection
```
Symbol ends in "-USD", "-USDT", "BTC", "ETH", "SOL" → Crypto
Symbol matches option pattern (e.g. "SPX 5500C") → Options
Symbol matches known ETF list → ETF
Otherwise → Stock (user confirms)
```

### Date Format Detection
```
Supported:
  YYYY-MM-DD        (preferred)
  MM/DD/YYYY
  DD/MM/YYYY
  MM-DD-YYYY
  "Mar 3, 2024"
  "3 Mar 2024"

Ambiguous (01/02/2024) → prompt user: "Is this Jan 2 or Feb 1?"
```

### Column Name Synonyms (auto-mapped)
```
Symbol:        Ticker, Symbol, Stock, Asset, Security
TradeDate:     Date, Trade Date, Transaction Date, Purchase Date
Action:        Type, Transaction Type, Activity
Quantity:      Shares, Units, Qty, Amount
PricePerShare: Price, Unit Price, Price Per Share, Cost Per Share
CostBasis:     Total Cost, Total Amount, Cost Basis, Basis
Fee:           Commission, Fee, Brokerage Fee
```

---

## Validation Rules

### Errors (block import — must fix)
| Check | Message |
|---|---|
| Symbol empty | "Symbol is required" |
| TradeDate invalid | "Cannot parse date — use YYYY-MM-DD" |
| Action unrecognised | "Unknown action — use BUY, SELL, DIVIDEND, DRIP, or SPLIT" |
| Quantity ≤ 0 | "Quantity must be greater than zero" |
| PricePerShare < 0 | "Price cannot be negative" |

### Warnings (allow with acknowledgement)
| Check | Message |
|---|---|
| SELL without prior BUY | "No matching buy lot found — lot may predate app tracking" |
| AssetType missing | "Asset type not detected for [SYMBOL] — will be set to Stock" |
| Sector missing | "Sector missing for [SYMBOL] — can be added after import" |
| Duplicate transaction | "Possible duplicate: same symbol, date, qty, price already exists" |
| CostBasis ≠ Qty × Price | "Cost basis doesn't match Qty × Price — may include fees" |
| Future date | "Trade date [DATE] is in the future" |
| I-Bond > $10k in year | "I-Bond purchase exceeds $10,000 annual limit for [YEAR]" |
| Crypto wash sale | "Note: wash sale rules do not apply to crypto (as of 2026)" |

---

## Import Flow

```
1. File picker (Files app or iCloud Drive)
2. Format detection (CSV / JSON / XLSX)
3. Column mapping UI (CSV) — auto-detected, user adjusts if needed
4. Preview & validation
   - Transaction count
   - Position count detected
   - Splits detected (listed individually)
   - DRIP transactions detected
   - Errors list (must fix)
   - Warnings list (review)
5. Conflict resolution (if existing data)
   - Merge: add new lots to existing positions
   - Replace: overwrite existing positions
   - Import as new: keep both (duplicates possible)
   - Per-symbol override available
6. Split confirmation (one-by-one for each detected split)
7. Import execution (atomic CoreData transaction)
8. Result screen
   - Counts: imported, created, warnings skipped
   - Undo button (60-second countdown timer)
```

---

## Undo

60-second window after import completes.
Full CoreData snapshot rollback — all imported transactions removed.
After 60 seconds: permanent. Snapshot discarded.

```swift
func performImport(_ transactions: [ImportedTransaction]) async throws {
    let snapshot = await coreDataStack.createSnapshot()
    do {
        try await processTransactions(transactions)
    } catch {
        await coreDataStack.restoreSnapshot(snapshot)
        throw error
    }
    importUndoSnapshot = snapshot
    startUndoTimer(duration: 60)
}
```

---

## Export Symmetry

The export format (Phase 15) is identical to the import format.
Full round-trip: Export → edit in Excel → re-import.
Export header includes full disclaimer as comment rows:
```csv
# ESTIMATED TAX DATA - FOR REFERENCE ONLY
# Generated: [date] | Tax profile: [status] | $[income] | [state] + [city]
# Cost basis reflects user-entered data, not broker confirmation.
# Consult a tax professional before filing. Not tax advice.
```

---

## Template

Bundled at `Resources/PortfolioApp_Import_Template.csv`
Available for download from import screen.
Includes inline comments explaining each column.
User deletes comment rows before importing.
