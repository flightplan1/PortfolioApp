# Xcode Project Setup — Phase 1

Follow these steps exactly. Many are one-time configurations that cannot be done via file writes.

---

## Step 1 — Create the Xcode Project

1. Open Xcode → **File → New → Project**
2. Choose **iOS → App**
3. Fill in:
   - **Product Name:** `PortfolioApp`
   - **Bundle Identifier:** `com.yourname.PortfolioApp` (use your Apple ID prefix)
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** **CoreData** ✓ (check this)
   - **Host in CloudKit:** ✓ (check this)
4. **Save location:** `~/Developer/PortfolioApp/` (the existing folder)
   - Xcode will create `PortfolioApp.xcodeproj` here
   - It will also create a `PortfolioApp/` subfolder — this is where your source goes

---

## Step 2 — Replace Auto-Generated Files

Xcode generates boilerplate files. Replace them with the files already written:

| Delete this (Xcode auto-generated) | Use this instead |
|---|---|
| `PortfolioApp/ContentView.swift` | `PortfolioApp/Views/ContentView.swift` |
| `PortfolioApp/PortfolioApp.swift` | `PortfolioApp/App/PortfolioAppApp.swift` |
| `PortfolioApp/Persistence.swift` | `PortfolioApp/App/PersistenceController.swift` |

**Do NOT delete** `PortfolioApp.xcdatamodeld` — you'll configure it in Step 4.

---

## Step 3 — Add Source Files to Xcode

In Xcode's Project Navigator, right-click each folder group and **Add Files**:

```
PortfolioApp/
├── App/
│   ├── PortfolioAppApp.swift         ✓ already exists (replace auto-generated)
│   └── PersistenceController.swift   ✓ add this
├── Models/Entities/
│   ├── BaseFinancialRecord+CoreData.swift
│   ├── Holding+CoreData.swift
│   ├── Lot+CoreData.swift
│   └── Transaction+CoreData.swift
├── Services/
│   ├── APIKeyManager.swift
│   ├── NetworkMonitor.swift
│   └── PriceService.swift
├── Utilities/
│   ├── DecimalExtensions.swift
│   ├── DateExtensions.swift
│   ├── AppColors.swift
│   ├── AppLockManager.swift
│   └── OptionsCalculator.swift
├── Views/
│   ├── ContentView.swift
│   ├── LockScreen.swift
│   └── Holdings/
│       ├── HoldingsListView.swift
│       └── AddHoldingView.swift
└── Resources/
    └── crypto-id-map.json            ← Add to bundle (check "Copy items if needed")
```

**Tip:** Create folder groups in Xcode to match the directory structure.

---

## Step 4 — Configure the CoreData Model (PortfolioApp.xcdatamodeld)

Open `PortfolioApp.xcdatamodeld` in Xcode. You'll see a default `Item` entity — delete it.

### 4a — Create BaseFinancialRecord (Abstract)

1. Add entity, name it `BaseFinancialRecord`
2. In the Data Model Inspector (right panel):
   - **Abstract Entity:** ✓ (check this — critical)
   - **Class → Module:** Current Product Module
   - **Class → Codegen:** Manual/None
3. Add these **attributes:**

| Name | Type | Optional |
|---|---|---|
| `ckRecordID` | String | ✓ |
| `ckRecordChangeTag` | String | ✓ |
| `lastModifiedDevice` | String | ✓ |
| `lastModifiedAt` | Date | ✓ |

### 4b — Create Holding

1. Add entity, name it `Holding`
2. In inspector:
   - **Parent Entity:** BaseFinancialRecord
   - **Class → Codegen:** Manual/None
3. Add these **attributes:**

| Name | Type | Optional |
|---|---|---|
| `id` | UUID | |
| `symbol` | String | |
| `name` | String | |
| `assetTypeRaw` | String | |
| `sector` | String | ✓ |
| `currency` | String | |
| `notes` | String | ✓ |
| `createdAt` | Date | |
| `isDRIPEnabled` | Boolean | |
| `dividendFrequencyRaw` | String | ✓ |
| `lastDividendPerShareRaw` | Decimal | ✓ |
| `lastExDividendDate` | Date | ✓ |
| `strikePriceRaw` | Decimal | ✓ |
| `expiryDate` | Date | ✓ |
| `optionTypeRaw` | String | ✓ |
| `isSection1256` | Boolean | |
| `bankFeeRaw` | Decimal | ✓ |
| `underlyingSymbol` | String | ✓ |

### 4c — Create Lot

1. Add entity, name it `Lot`
2. **Parent Entity:** BaseFinancialRecord
3. **Codegen:** Manual/None
4. Attributes:

| Name | Type | Optional |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | |
| `lotNumber` | Integer 32 | |
| `originalQtyRaw` | Decimal | |
| `originalCostBasisPerShareRaw` | Decimal | |
| `splitAdjustedQtyRaw` | Decimal | |
| `splitAdjustedCostBasisPerShareRaw` | Decimal | |
| `totalCostBasisRaw` | Decimal | |
| `remainingQtyRaw` | Decimal | |
| `purchaseDate` | Date | |
| `settlementDate` | Date | ✓ |
| `isClosed` | Boolean | |
| `isDeleted` | Boolean | |
| `deletedAt` | Date | ✓ |
| `createdAt` | Date | |
| `lotSourceRaw` | String | |
| `linkedDividendEventId` | UUID | ✓ |
| `splitHistoryData` | Binary Data | ✓ |
| `taxTreatmentOverrideRaw` | String | ✓ |

### 4d — Create Transaction

1. Add entity, name it `Transaction`
2. **Parent Entity:** BaseFinancialRecord
3. **Codegen:** Manual/None
4. Attributes:

| Name | Type | Optional |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | |
| `lotId` | UUID | ✓ |
| `typeRaw` | String | |
| `tradeDate` | Date | |
| `settlementDate` | Date | ✓ |
| `quantityRaw` | Decimal | |
| `pricePerShareRaw` | Decimal | |
| `totalAmountRaw` | Decimal | |
| `feeRaw` | Decimal | |
| `lotMethodRaw` | String | |
| `importSessionId` | UUID | ✓ |
| `notes` | String | ✓ |
| `isDeleted` | Boolean | |
| `deletedAt` | Date | ✓ |
| `deletionReasonRaw` | String | ✓ |
| `createdAt` | Date | |

### 4e — Set Current Model Version

1. Select `PortfolioApp.xcdatamodeld` in navigator
2. **Editor → Add Model Version** → name it `PortfolioApp v1`
3. In the File Inspector, set **Current Version** to `PortfolioApp v1`

---

## Step 5 — CloudKit Capability

1. Select your project in the navigator
2. **Signing & Capabilities** tab
3. Click **+ Capability**
4. Add **CloudKit**
5. Under CloudKit Containers, add: `iCloud.com.yourname.PortfolioApp`
   - This must match the identifier in `PersistenceController.swift`
6. Also add **Background Modes** capability → check **Remote Notifications**

---

## Step 6 — Update PersistenceController.swift

Change the CloudKit container ID to match yours:

```swift
// In PersistenceController.swift, line ~43:
description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
    containerIdentifier: "iCloud.com.YOURNAME.PortfolioApp"  // ← update this
)
```

---

## Step 7 — Add Required Frameworks

These are used by the written code. Most are auto-linked on iOS, but verify:

- `CoreData.framework` — auto-linked
- `CloudKit.framework` — auto-linked when CloudKit capability added
- `Network.framework` — auto-linked (NetworkMonitor uses NWPathMonitor)
- `LocalAuthentication.framework` — may need manual add for AppLockManager
  - Project → Build Phases → Link Binary With Libraries → + → LocalAuthentication

---

## Step 8 — Info.plist — Face ID Usage Description

1. Open `Info.plist`
2. Add key: `NSFaceIDUsageDescription`
3. Value: `PortfolioApp uses Face ID to protect your financial data.`

---

## Step 9 — Custom Fonts (Optional but recommended)

The design spec uses:
- **Syne** (headers) — download from Google Fonts
- **JetBrains Mono** (numbers) — download from JetBrains
- **Mulish** (body) — download from Google Fonts

To add:
1. Drag `.ttf`/`.otf` files into `Resources/Fonts/`
2. In `Info.plist`, add `UIAppFonts` array with each font filename
3. The app will fall back to system fonts if these aren't added (safe for Phase 1)

---

## Step 10 — Add Finnhub API Key

The app won't fetch prices until you add your key:

1. Get a free key at https://finnhub.io
2. Run the app once
3. In the Xcode debugger console, or add a temporary settings screen, call:
   ```swift
   try? APIKeyManager.saveFinnhubKey("your_key_here")
   ```
   Or add the Settings screen (Phase 2) which will have a key entry field.

---

## Verification Checklist

- [ ] App launches without crash
- [ ] CoreData store loads (check console for "✅ CoreData store loaded")
- [ ] Holdings list shows empty state with "Add Holding" button
- [ ] Add Holding form opens and saves a holding
- [ ] Holding appears in list
- [ ] Lock screen appears on first launch (if biometric lock enabled)
- [ ] Offline banner appears when airplane mode enabled
