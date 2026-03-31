# UI Reference

## Design Language

**Aesthetic:** Dark, refined, data-dense. Finance-grade — not consumer-playful.
**Theme:** Dark background only. No light mode planned (Phase 1).

### Typography
```
Display / Headers:    Syne (700, 800 weight)
Monospace / Numbers:  JetBrains Mono (500, 600, 700)
Body / Labels:        Mulish (400, 500, 600, 700)
```

### Color Tokens
```swift
let bg          = "#080C14"   // App background
let surface     = "#0D1520"   // Card background
let surfaceAlt  = "#111927"   // Nested card / stat tile
let surfaceDeep = "#090E18"   // Deepest nesting (sell sheet sections)
let border      = "#1A2535"   // Standard border
let borderLight = "#1E2D42"   // Lighter border

let text        = "#E8EFF8"   // Primary text
let textSub     = "#6B7FA0"   // Secondary text / labels
let textMuted   = "#3D5070"   // Muted / disabled / footer

let green       = "#00D4A8"   // Positive P&L, long-term, DRIP
let greenDim    = "#00D4A815" // Green background tint
let greenBorder = "#00D4A830" // Green border

let red         = "#FF4D6A"   // Negative P&L, short-term, sell
let redDim      = "#FF4D6A15"
let redBorder   = "#FF4D6A30"

let blue        = "#3B8EF0"   // Primary action, active tab, Stock chip
let blueDim     = "#3B8EF015"
let blueBorder  = "#3B8EF030"

let gold        = "#F5A623"   // Warning, approaching LT, Options chip
let goldDim     = "#F5A62315"
let goldBorder  = "#F5A62330"

let purple      = "#A855F7"   // Options type chip
let purpleDim   = "#A855F715"

let teal        = "#06B6D4"   // ETF chip, yield
let tealDim     = "#06B6D418"
```

### Type Chips (Asset Type Badges)
```
STOCK   → blue (#3B8EF0)
ETF     → teal (#06B6D4)
CRYPTO  → gold (#F5A623)
OPTION  → purple (#A855F7)
CASH    → green (#00D4A8)
TREAS   → slate (#94a3b8)
```

### Status Badges
```
LONG-TERM   → green
SHORT-TERM  → red
⚡ Xd TO LT → gold (when daysToLT ≤ 60)
DRIP        → green
SPLIT ADJ   → blue
EXP Xd      → gold (options expiry warning)
APPLIED ✓   → green (split applied)
```

### Card Border Colors (lot cards)
```
Long-term lot     → greenBorder
Approaching LT    → goldBorder
Short-term lot    → border (default)
```

---

## Screen Layout

### Navigation
```
TabView (bottom navigation)
  ⬡  Dashboard
  ◈  Holdings
  ◎  P&L
  ◉  News
  ◌  Settings
```

Active tab: blue dot indicator below icon.
Tab bar: fixed bottom, blurred background.

### Standard Card
```swift
// Card component
background: surface (#0D1520)
border: 1px solid border (#1A2535)
borderRadius: 18
padding: 16px
```

### Stat Tile (inside cards)
```swift
background: surfaceAlt (#111927)
borderRadius: 12
padding: 10px 12px
label: 9px JetBrains Mono, uppercase, textMuted, letterSpacing 0.7
value: 13px JetBrains Mono, 700 weight
```

### Section Title
```swift
fontSize: 10, JetBrains Mono, uppercase, letterSpacing 1, textMuted
```

---

## Balance Hide Feature

Toggle: 👁 (visible) / 🙈 (hidden) — tap to toggle
Located: top-right area of Dashboard header, next to portfolio value

When hidden:
- Monetary values: `filter: blur(7px)` — layout unchanged
- Percentages: remain visible (public market data)
- Stock prices: remain visible (public market data)
- All `~` estimated values: blurred

Implementation:
```swift
// CSS blur — preserves layout, doesn't collapse elements
.hidden-balance {
    filter: blur(7px);
    user-select: none;
}
```

---

## Disclaimer Visual Patterns

### Tier 3 — Gold Warning Card (Sell Sheet top)
```
background: goldDim (#F5A62315)
border: 1px solid goldBorder (#F5A62330)
borderRadius: 12
padding: 12px 14px
icon: ⚠️
title: "Tax Estimate Notice" — 11px JetBrains Mono, 700, gold
body: 11px Mulish, gold at 88% opacity, lineHeight 1.55
```

### Tier 2 — Inline inside stat box
```
border-top: 1px solid border
padding-top: 7px
text: 10px JetBrains Mono, textMuted
format: "~ Federal only · Single filer · Entered basis · Not tax advice"
```

### Tier 1 — Footer card
```
background: surface or surfaceAlt
border: 1px solid border
borderRadius: 10–12
padding: 10px–12px
text: 10px JetBrains Mono, textMuted, lineHeight 1.6–1.7, centered
```

### `~` Tilde Convention
All estimated values: prepend or append `~` to the line label.
Not to the value itself — to the label. e.g. "Est. federal tax ~" not "~$4,902".

### Tax profile incomplete banner
```
background: redDim
border: redBorder
non-dismissible until profile completed
text: "⚠️ Tax profile incomplete — Estimates use Single filer, $70k defaults"
CTA: "Complete your profile →"
```

---

## Lot Progress Bar

```
Height: 5–6px
Background: border (#1A2535)
Progress fill:
  < 50%:  red (#FF4D6A)
  50–90%: blue (#3B8EF0)
  ≥ 90%:  gradient gold→green
borderRadius: 99 (pill)
```

Label: "{daysHeld} / 366 days" — never "365 days"
Below bar (if daysToLT ≤ 60): gold advisory box with est. tax saving

---

## Position Detail — Tab Structure

```
Overview   |   Lots   |   Dividends   |   News   |   Industry
```

Tab pill style:
```
active:   background blueDim, color blue, border blueBorder
inactive: background transparent, color textSub, border border
```

---

## Sell Sheet

Bottom sheet (slides up from bottom).
Drag indicator at top (36px wide, 4px tall, border color).
Max height: 85vh, scrollable.
Backdrop: rgba(0,0,0,0.73), tappable to dismiss.

Order of content:
1. Drag handle
2. "Sell Lot N" title
3. Lot subtitle (symbol, qty, cost basis)
4. **Tier 3 disclaimer (gold warning card)**
5. LT advisory (if applicable — gold)
6. Quantity slider
7. Tax breakdown card (with `~` on all tax lines)
8. **Tier 1 disclaimer footer**
9. Cancel + Confirm Sell buttons

---

## Sparkline Chart

52-week price history from Finnhub historical data.
SVG path with gradient fill.
Green (#00D4A8) for positive trend.
Red (#FF4D6A) for negative trend.
Live dot at current price endpoint.
52-week range bar below chart (low → high with position indicator).

---

## Mockup Files (Reference Only — Not Swift Code)

Located in outputs from planning session. Use as visual reference for SwiftUI implementation.

| File | Contents |
|---|---|
| `app-mockup.jsx` | Full 5-tab app (Dashboard, Holdings, P&L, News, Settings) |
| `position-detail.jsx` | Position detail screen — 5 tabs including Sell Sheet |
| `onboarding.jsx` | 4-step tax profile onboarding |
| `pnl-screen.jsx` | Standalone P&L screen |

These are React/JSX prototypes rendered in browser.
The SwiftUI implementation should match their visual design and data structure precisely.
All disclaimer tiers are already implemented in position-detail.jsx — replicate in SwiftUI.
