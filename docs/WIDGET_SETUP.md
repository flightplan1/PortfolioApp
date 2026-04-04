# PortfolioWidget — Xcode Setup

The widget code is written and ready. You need to add the WidgetKit extension target manually in Xcode.

---

## Step 1 — Add Widget Extension Target

1. Open `PortfolioApp.xcodeproj` in Xcode
2. **File → New → Target**
3. Choose **iOS → Widget Extension**
4. Fill in:
   - **Product Name:** `PortfolioWidget`
   - **Bundle Identifier:** `com.yourname.PortfolioApp.PortfolioWidget`
   - **Include Configuration App Intent:** ✗ (uncheck — not needed)
5. Click **Finish**
6. When prompted "Activate PortfolioWidget scheme?", click **Activate**

---

## Step 2 — Replace Auto-Generated Widget File

Xcode creates `PortfolioWidget/PortfolioWidget.swift` automatically. Replace its contents with the file already written at:

```
PortfolioApp/PortfolioWidget/PortfolioWidget.swift
```

Or, in Xcode: delete the auto-generated file, then drag in the existing one.

---

## Step 3 — Add App Group Capability (Both Targets)

The widget reads data from the main app via a shared `UserDefaults` app group.

**Do this for BOTH the main app target AND the widget target:**

1. Select your project in the navigator
2. Select the target (first main app, then widget)
3. **Signing & Capabilities** → **+ Capability** → **App Groups**
4. Click **+** and add: `group.com.yourname.PortfolioApp`
   - Use the same Apple Developer team for both targets

**Then update the bundle identifier constant in two places:**

In `PortfolioWidget/PortfolioWidget.swift`, line 8:
```swift
private let appGroupID = "group.com.yourname.PortfolioApp"
```

In `PortfolioApp/Services/WidgetDataWriter.swift`, line 12:
```swift
private static let appGroupID = "group.com.yourname.PortfolioApp"
```

Replace `yourname` with your actual bundle ID prefix in both files.

---

## Step 4 — Add WidgetKit to Main App (if needed)

`WidgetDataWriter.swift` imports `WidgetKit`. If the main app target doesn't already link it:

1. Select main app target → **Build Phases** → **Link Binary With Libraries**
2. Click **+** → search `WidgetKit` → **Add**

---

## Step 5 — Verify

1. Build both targets (⌘B on each scheme)
2. Run the main app on a device or simulator
3. Long-press the home screen → **+** → search "Portfolio"
4. Add the small or medium widget

---

## How Data Flows

```
Main App (DashboardView)
  └── priceService.lastFetchedAt changes
      └── WidgetDataWriter.write(totalValue:todayChange:todayChangePct:)
          └── UserDefaults(suiteName: "group.com.yourname.PortfolioApp")
              └── WidgetCenter.shared.reloadTimelines(ofKind: "PortfolioWidget")
                  └── PortfolioWidget reads snapshot → displays in widget
```

Widget refreshes automatically every 15 minutes as a fallback.
The main app triggers an immediate reload on every price refresh.
