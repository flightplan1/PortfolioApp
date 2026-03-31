# Disclaimers

## Principle: Tiered System

Too many warnings causes disclaimer blindness. Use the right tier for each context.
Never use ad-hoc disclaimer wording — always use the canonical strings below.

---

## Canonical Disclaimer Strings

### Short (Tier 1 — footers, persistent)
> *Estimated only · Not tax advice*

### Medium (Tier 2 — inline with numbers)
> *Tax figures are estimates based on your profile. Actual liability may differ. Not tax advice.*

### Full (Tier 3 — sell sheet, onboarding)
> *All tax calculations are estimates only, based on the cost basis and tax profile information you have entered. They do not constitute tax advice and may differ from your actual tax liability. Figures do not account for AMT, carry-forward losses, state-specific deductions, or wash sale adjustments. Consult a qualified tax professional before making investment decisions based on these estimates.*

### Lots Tab Specific (Tier 1 variant)
> *Tax lot figures are estimates only based on your entered cost basis. Verify all lot details with your broker or custodian. Long-Term status requires holding more than 366 days (IRS rule). Not tax advice · Consult a qualified tax professional.*

### Sell Sheet Footer (Tier 1 variant — includes profile context)
> *~ Estimated only · Based on Single filer, $70k income · Not tax advice*
> *Verify cost basis with your broker before filing*

---

## `~` Tilde Convention

Every estimated monetary value or rate is marked with `~`.
Apply to the **label**, not the value itself.

```
✓ Correct:   "Est. federal tax ~"     "$4,902"
✓ Correct:   "Total est. tax ~"       "$7,473"
✓ Correct:   "Est. net proceeds ~"    "$182,527"

✗ Wrong:     "Federal tax"            "~$4,902"
✗ Wrong:     "Net proceeds"           "$182,527"  (no tilde = looks exact)
```

Users learn: `~` = estimated. Consistent application is key.

---

## Placement Map

### 1. Sell Sheet
- **TOP:** Tier 3 full warning card (gold, before any numbers are shown)
- Section title: "Tax Estimate (Federal + NY + NYC)" — not just "Estimate"
- All tax line labels: include `~` (e.g. "Federal ~ (LT 15%)")
- Net proceeds label: "Est. net proceeds ~"
- **BOTTOM:** Tier 1 with filing status + income + "Verify with broker"

### 2. Lot Cards (Lots Tab)
- Inside tax estimate box: Tier 2 inline
- Format: "~ Federal only · Single filer · Entered basis · Not tax advice"
- Both values in box: labelled with "Est. X ~"

### 3. Lots Tab Footer
- Tier 1 persistent card at bottom of lots list
- Always visible regardless of scroll position (static, not sticky)
- Includes 366-day IRS rule mention

### 4. P&L Realized Tab — Year Summary
- Tier 1 below the summary table
- Full disclaimer with "fed + state + city" notation

### 5. Dashboard Realized P&L Card
- `~` on estimated values only
- Small legend: "~ Estimated · See P&L tab for detail"

### 6. Per-Position P&L (Holdings list)
- If tax profile set: show "Est. after-tax ~" as 3rd line under P&L
- If tax profile incomplete: don't show after-tax estimate at all

### 7. Onboarding Completion Screen
- Tier 3 full text with acknowledgement tap required
- One-time only — stored as `onboardingAcknowledged = true` in KV Store
- Never shown again unless tax profile is reset

### 8. Tax Profile Incomplete Banner
- Non-dismissible — persists until profile completed
- Shown on any screen displaying tax figures
- Red background (redDim + redBorder)
```
⚠️ Tax profile incomplete
Estimates shown use Single filer, $70k income defaults
and may be significantly inaccurate.
[Complete your profile →]
```

### 9. Settings — Tax Profile Footer
```
Tax figures throughout the app are estimates only.
Not tax advice.
Rates sourced from tax-rates.json v2026.1 · Updated Jan 15, 2026
```

### 10. CSV Export Header
```csv
# ESTIMATED TAX DATA - FOR REFERENCE ONLY
# Generated: [date] | Tax profile: [status] | $[income] | [state] + [city]
# Cost basis reflects user-entered data, not broker confirmation.
# Consult a tax professional before filing. Not tax advice.
#
```

---

## Special Case Disclaimers

### TIPS Phantom Income
Display prominently in TIPS position detail (not just a footnote):
```
⚠️ TIPS Inflation Adjustment
The annual inflation adjustment to your TIPS principal
is taxable as ordinary income in the year it accrues —
even though you don't receive it as cash.
This is known as "phantom income."
The amount is NOT automatically calculated here.
Consult your tax professional or Form 1099-OIP from your broker.
```

### Crypto Wash Sale
Display in any crypto sell flow:
```
ℹ️ Crypto & Wash Sale Rules
As of 2026, the wash sale rule does not apply to cryptocurrency.
However, this may change with future legislation.
Monitor IRS guidance if you are harvesting crypto losses.
```

### MMF Not FDIC Insured
Display in MMF position detail:
```
ℹ️ Money market funds are not FDIC insured and
are not guaranteed to maintain their $1.00 per share value.
In rare circumstances, they may lose value.
```

### AMT Warning (large gains)
Trigger: capital gain > $100,000 on any single sale
```
⚠️ Large gains may trigger Alternative Minimum Tax (AMT).
This app does not calculate AMT.
Consult a tax professional before proceeding.
```

### Options OCC Split Adjustment
Display on any options position where underlying stock has split:
```
⚠️ OCC Contract Adjustment
[SYMBOL] has undergone a stock split.
Options contracts on split stocks are adjusted by the OCC
and the terms may differ from standard contracts.
P&L calculation is paused until you confirm adjusted contract terms.
Verify current contract specifications with your broker.
[Update Contract Terms]
```

### Tax Rates Outdated
Trigger: effectiveYear in tax-rates.json < current calendar year
```
⚠️ Tax rates may be outdated
The loaded tax rates are from [YEAR].
Please verify and update your remote tax rates JSON.
All tax estimates may be inaccurate until updated.
[Open Settings →]
```

---

## What Disclaimers Do NOT Cover

The following are known gaps — disclaim separately where relevant:
- AMT (Alternative Minimum Tax) — not calculated
- Carry-forward losses from prior years — not tracked
- State-specific deductions and credits — not modeled
- Tax treaty benefits — not modeled
- Qualified opportunity zone investments — not modeled
- Foreign tax credits — not modeled
- Net operating losses — not modeled
- Depreciation recapture — not modeled
- Kiddie tax — not modeled

The Tier 3 full disclaimer mentions AMT and carry-forward losses explicitly.
The others are covered by the general "consult a tax professional" language.
