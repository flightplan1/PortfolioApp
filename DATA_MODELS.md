# Data Models

All entities use `Decimal` for monetary values. All entities inherit `BaseFinancialRecord` for CloudKit conflict tracking.

---

## BaseFinancialRecord (Abstract — all financial entities inherit this)

| Field | Type | Notes |
|---|---|---|
| `ckRecordID` | String? | CloudKit record ID |
| `ckRecordChangeTag` | String? | Version token for conflict detection |
| `lastModifiedDevice` | String? | Device name — shown in conflict UI |
| `lastModifiedAt` | Date? | For conflict resolution ordering |

---

## Holding

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `symbol` | String | Ticker e.g. "NVDA", "BTC" |
| `name` | String | Full company/asset name |
| `assetType` | String (Enum) | stock / etf / crypto / options / treasury |
| `sector` | String? | For allocation breakdown |
| `currency` | String | Default "USD" |
| `isDRIPEnabled` | Bool | Auto-reinvest dividends |
| `dividendFrequency` | String? (Enum) | monthly / quarterly / semiAnnual / annual / irregular |
| `lastDividendPerShare` | Decimal? | For yield calculation |
| `lastExDividendDate` | Date? | For next dividend estimate |
| `notes` | String? | User investment thesis / notes |
| `createdAt` | Date | |
| — Options specific — | | |
| `strikePrice` | Decimal? | Options only |
| `expiryDate` | Date? | Options only |
| `optionType` | String? (Enum) | call / put |
| `isSection1256` | Bool | SPX, NDX, RUT etc — 60/40 tax treatment |
| `bankFee` | Decimal? | Per-contract fee (overrides app default) |
| `underlyingSymbol` | String? | Options only |

---

## Lot

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | Foreign key to Holding |
| `lotNumber` | Int | Display label (Lot 1, 2, 3) |
| `originalQty` | Decimal | Pre-split quantity — preserved forever |
| `originalCostBasisPerShare` | Decimal | Pre-split basis — preserved forever |
| `splitAdjustedQty` | Decimal | Current quantity after all splits |
| `splitAdjustedCostBasisPerShare` | Decimal | Current per-share basis after splits |
| `totalCostBasis` | Decimal | Always = originalQty × originalCostBasisPerShare (unchanged by splits) |
| `purchaseDate` | Date | **Trade date** — used for IRS holding period |
| `settlementDate` | Date? | T+1 or T+2 — informational only |
| `remainingQty` | Decimal | Decreases on partial sells |
| `isClosed` | Bool | True when fully sold |
| `isDeleted` | Bool | Soft delete only |
| `deletedAt` | Date? | |
| `lotSource` | String (Enum) | manual / drip / import / split |
| `linkedDividendEventId` | UUID? | If created by DRIP |
| `splitHistory` | [UUID] | SplitEvent IDs applied to this lot |
| `taxTreatmentOverride` | String? (Enum) | standard / section1256 / crypto |
| `createdAt` | Date | |

---

## Transaction

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | |
| `lotId` | UUID? | Links to specific lot |
| `type` | String (Enum) | buy / sell / dividend / drip / split / transferIn / transferOut |
| `tradeDate` | Date | **IRS holding period basis — always trade date** |
| `settlementDate` | Date? | Informational only |
| `quantity` | Decimal | |
| `pricePerShare` | Decimal | |
| `totalAmount` | Decimal | |
| `fee` | Decimal | Bank/broker fee |
| `lotMethod` | String (Enum) | fifo / lifo / highestCost / specificLot |
| `isDeleted` | Bool | Soft delete only |
| `deletedAt` | Date? | |
| `deletionReason` | String? (Enum) | userDeleted / importRollback / splitReversal |
| `importSessionId` | UUID? | Which import created this |
| `notes` | String? | |
| `createdAt` | Date | |

---

## RealizedTransaction

Stores the complete tax breakdown at time of sale — locked in forever regardless of future rate changes.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `lotId` | UUID | Originating lot |
| `holdingId` | UUID | |
| `symbol` | String | Denormalized for display |
| `saleDate` | Date | Trade date of sale |
| `quantity` | Decimal | |
| `salePricePerShare` | Decimal | |
| `grossProceeds` | Decimal | qty × salePrice |
| `costBasis` | Decimal | Including fees |
| `capitalGain` | Decimal | grossProceeds − costBasis |
| `isLongTerm` | Bool | Based on 366-day IRS rule |
| `taxTreatment` | String (Enum) | standard / section1256 / crypto |
| `federalTax` | Decimal | Stacked bracket calculation |
| `niitTax` | Decimal | 3.8% if above threshold |
| `stateTax` | Decimal | Per state config |
| `cityTax` | Decimal | Per city config |
| `totalTax` | Decimal | Sum of all four |
| `netProceeds` | Decimal | grossProceeds − totalTax |
| `effectiveRate` | Decimal | totalTax / capitalGain |
| `taxYear` | Int | Calendar year of sale |
| `filingStatusSnapshot` | String | Filing status at time of sale |
| `incomeSnapshot` | Decimal | Income at time of sale |
| `taxRatesVersionSnapshot` | String | Which JSON version was used |

---

## DividendEvent

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | |
| `symbol` | String | Denormalized |
| `payDate` | Date | |
| `exDividendDate` | Date? | |
| `dividendPerShare` | Decimal | |
| `sharesHeld` | Decimal | On record date |
| `grossAmount` | Decimal | dividendPerShare × sharesHeld |
| `isReinvested` | Bool | true = DRIP |
| `reinvestedShares` | Decimal? | Shares if reinvested |
| `reinvestedPricePerShare` | Decimal? | Price at reinvestment |
| `linkedLotId` | UUID? | New lot created if DRIP |
| `linkedCashPositionId` | UUID? | Cash position credited if not DRIP |
| `entryMethod` | String (Enum) | auto / manual |
| `isQualified` | Bool | Stored but not surfaced in UI (future use) |

---

## SplitEvent

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `holdingId` | UUID | |
| `symbol` | String | Denormalized |
| `splitDate` | Date | Effective date |
| `ratioNumerator` | Int | e.g. 10 in 10:1 |
| `ratioDenominator` | Int | e.g. 1 in 10:1 |
| `splitMultiplier` | Decimal | numerator ÷ denominator |
| `isForward` | Bool | true = more shares |
| `entryMethod` | String (Enum) | auto / manual |
| `appliedAt` | Date | When app processed it |
| `snapshotBeforeShares` | Decimal | Audit trail |
| `snapshotAfterShares` | Decimal | Audit trail |

---

## SplitSnapshot (Local only — not CloudKit synced)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `splitEventId` | UUID | |
| `snapshotData` | Binary | Serialized lot states before split |
| `createdAt` | Date | |
| `revertableUntil` | Date | createdAt + 24 hours |

---

## CashPosition

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `name` | String | e.g. "Fidelity Cash" |
| `type` | String (Enum) | usd / moneyMarket |
| `balance` | Decimal | Current balance — never negative |
| `annualYieldRate` | Decimal | APY — manual entry |
| `institution` | String? | Broker/bank name |
| `ticker` | String? | MMF ticker e.g. SPAXX for auto-yield fetch |
| `notes` | String? | |
| `createdAt` | Date | |
| `lastUpdatedAt` | Date | |

---

## CashTransaction

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `cashPositionId` | UUID | |
| `type` | String (Enum) | deposit / withdrawal / interestEarned / buyDeduction / sellProceeds / dividendReceived |
| `amount` | Decimal | Always positive — type determines direction |
| `date` | Date | |
| `linkedTransactionId` | UUID? | Stock buy/sell transaction if auto-generated |
| `notes` | String? | |

---

## TreasuryPosition

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `type` | String (Enum) | tBill / tNote / tBond / tips / iBond |
| `cusip` | String? | 9-digit identifier |
| `nickname` | String? | User label |
| `faceValue` | Decimal | Par value at maturity |
| `purchasePrice` | Decimal | Actual amount paid |
| `purchaseDate` | Date | |
| `maturityDate` | Date | |
| `couponRate` | Decimal | Annual rate (0 for T-Bills) |
| `couponFrequency` | String (Enum) | semiAnnual / none |
| `ytmAtPurchase` | Decimal | Locked in at purchase |
| `currentYTM` | Decimal? | Manual update |
| `currentMarketValue` | Decimal? | Manual update |
| `quantity` | Int | Number of bonds |
| `institution` | String? | TreasuryDirect / broker |
| `isMatured` | Bool | Auto-set when maturityDate passes |
| `maturityAlertDays` | Int | Default 30 |
| — TIPS specific — | | |
| `inflationAdjustedPrincipal` | Decimal? | Updated manually |
| `lastCPIUpdate` | Date? | |
| `accruedInflationAdjustment` | Decimal? | |
| — I-Bond specific — | | |
| `fixedRate` | Decimal? | Never changes after purchase |
| `currentInflationRate` | Decimal? | Updated manually each May/Nov |
| `compositeRate` | Decimal? | Computed: fixed + (2×inflation) + (fixed×inflation) |
| `redemptionPenaltyMonths` | Int? | 3 months interest if redeemed < 5yr |
| `penaltyExpiryDate` | Date? | 5yr anniversary |
| `isRedeemable` | Bool | False for first 12 months |

---

## CouponPayment

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `treasuryPositionId` | UUID | |
| `paymentDate` | Date | |
| `amount` | Decimal | Gross coupon |
| `isReceived` | Bool | Toggle when arrives |
| `linkedCashPositionId` | UUID? | Which cash position it went to |

---

## PriceSnapshot (Local only — not CloudKit synced)

| Field | Type | Notes |
|---|---|---|
| `symbol` | String | Primary key |
| `currentPrice` | Decimal | |
| `previousClosePrice` | Decimal | |
| `openPrice` | Decimal? | |
| `highPrice` | Decimal? | |
| `lowPrice` | Decimal? | |
| `volume` | String? | |
| `fetchedAt` | Date | Staleness check: warn if > 15 min |
| `source` | String (Enum) | finnhub / coingecko |

---

## NewsArticle (Local only — not CloudKit synced)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `symbol` | String | |
| `headline` | String | |
| `summary` | String? | |
| `source` | String | |
| `url` | String | |
| `publishedAt` | Date | |
| `sentiment` | String (Enum) | positive / neutral / negative |
| `isBreaking` | Bool | publishedAt < 1 hour ago |
| `hasBeenRead` | Bool | |
| `cachedAt` | Date | Expire after 30 min |

---

## ImportSession

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `importedAt` | Date | |
| `sourceFileName` | String | |
| `format` | String (Enum) | csv / json / xlsx |
| `transactionCount` | Int | |
| `warningCount` | Int | |
| `status` | String (Enum) | completed / rolledBack |
| `snapshotData` | Binary? | Pre-import snapshot — nil after 60s |

---

## TaxProfile (iCloud KV Store — not CoreData)

Not a CoreData entity. Stored in `NSUbiquitousKeyValueStore`.

| Key | Type | Default | Notes |
|---|---|---|---|
| `filingStatus` | String | "single" | single / mfj / hoh |
| `annualIncome` | Int | 70000 | **Default $70k** |
| `state` | String | "" | State name |
| `city` | String | "" | City name |
| `residency` | String | "resident" | resident / nonresident |
| `defaultLotMethod` | String | "fifo" | fifo / lifo / highestCost / specificLot |
| `defaultBankFee` | Decimal | 9.99 | Per options contract |
| `taxRatesVersion` | String | "2026.1" | Bundled version |
| `onboardingAcknowledged` | Bool | false | Tax disclaimer acknowledged |
