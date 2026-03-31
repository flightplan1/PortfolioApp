# API Strategy

## Decision: Finnhub (primary) + CoinGecko (crypto)

Yahoo Finance was explicitly rejected. See rationale below.

---

## Finnhub

**Base URL:** `https://finnhub.io/api/v1`
**Auth:** `X-Finnhub-Token: {key}` header
**Free tier:** 60 calls/min, 30 calls/sec
**API key storage:** iOS Keychain only — never hardcoded, never UserDefaults

### Endpoints Used

```
GET /quote?symbol={symbol}
    → Real-time price, prev close, open, high, low
    → Used for: PriceSnapshot updates

GET /stock/candle?symbol={symbol}&resolution=D&from={unix}&to={unix}
    → Historical OHLC data
    → Used for: sparkline chart, historical P&L reconstruction

GET /company-news?symbol={symbol}&from={date}&to={date}
    → News articles with sentiment scores
    → Use REST polling (not WebSocket — WebSocket unreliable on free tier)
    → Refresh every 30 minutes while app active

GET /calendar/earnings?from={date}&to={date}
    → Earnings dates, est EPS, actual EPS
    → Refresh weekly

GET /stock/dividend?symbol={symbol}&from={date}&to={date}
    → Dividend history, ex-dividend dates, pay dates
    → Used for: DRIP tracking, next dividend estimate

GET /stock/split?symbol={symbol}&from={date}&to={date}
    → Split history with ratios
    → Check daily on app launch for all held symbols

GET /stock/profile2?symbol={symbol}
    → Company name, sector, market cap
    → Fetch once on holding creation, cache in Holding entity
```

### Rate Limit Strategy

Never make per-symbol individual calls. Always batch:

```swift
// Good: one call per endpoint for all symbols
let symbols = holdings.map { $0.symbol }.joined(separator: ",")
// Some Finnhub endpoints support comma-separated symbols

// Good: one call per symbol, but throttled with delay
for symbol in symbols {
    await fetchPrice(symbol)
    try await Task.sleep(nanoseconds: 100_000_000) // 100ms between calls
}

// Bad: parallel calls for all symbols simultaneously
await withTaskGroup { /* DON'T DO THIS */ }
```

Refresh schedule:
- On app foreground: batch fetch all prices
- Every 60 seconds while active
- News: every 30 minutes
- Earnings: weekly
- Splits: on launch daily

---

## CoinGecko

**Base URL:** `https://api.coingecko.com/api/v3`
**Auth:** None for free tier
**Free tier:** 30 calls/min
**Coverage:** 14,000+ cryptocurrencies — strictly better than Finnhub for crypto

### Endpoints Used

```
GET /simple/price?ids={id1},{id2}&vs_currencies=usd&include_24hr_change=true
    → Batch crypto prices + 24hr change
    → ids: coingecko IDs (bitcoin, ethereum, solana, etc.)
    → NOT ticker symbols — must map symbol → coingecko ID

GET /coins/{id}/market_chart?vs_currency=usd&days=365
    → Historical price data for sparkline
```

### Symbol → CoinGecko ID Mapping

Bundle a `crypto-id-map.json` for common symbols:
```json
{
  "BTC": "bitcoin",
  "ETH": "ethereum",
  "SOL": "solana",
  "ADA": "cardano",
  "MATIC": "matic-network",
  "DOT": "polkadot",
  "AVAX": "avalanche-2",
  "LINK": "chainlink",
  "UNI": "uniswap",
  "ATOM": "cosmos"
}
```

Unknown symbols: search `/search?query={symbol}` and let user confirm the match.

---

## Why Yahoo Finance Was Rejected

Yahoo Finance (yfinance) is an unofficial scraper — not a real API.

| Issue | Detail |
|---|---|
| No official support | Yahoo does not maintain or support yfinance |
| ToS violation | Scraping violates Yahoo's Terms of Service |
| App Store risk | Apple may reject app if they identify ToS-violating network calls |
| Silent failures | Can break overnight with no error — shows stale prices silently |
| Rate limiting | Arbitrary, unpublished, enforced via IP bans |
| Shrinking access | Yahoo restricting historical data to paid Gold tier ($50/mo) |
| No SLA | Zero recourse when it breaks |

**Decision is final — do not reintroduce Yahoo Finance.**

---

## Manual Entry Only (No API)

| Data | Reason |
|---|---|
| Options prices (real-time) | Finnhub free tier doesn't cover options chains reliably |
| MMF 7-day yield | No reliable free API for SPAXX, VMFXX etc. |
| I-Bond rates | TreasuryDirect publishes May/Nov; no API |
| TIPS inflation adjustment | TreasuryDirect only; manual update |
| Treasury current market value | Secondary market prices unavailable on free APIs |

---

## Offline Handling

```swift
// NetworkMonitor.swift (NWPathMonitor)
class NetworkMonitor: ObservableObject {
    @Published var isConnected = true

    func startMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: .global())
    }
}
```

Offline behavior:
- Use last cached PriceSnapshot (CoreData local)
- Show "Last updated X min ago" timestamp on all prices
- If price > 15 min old: show amber warning indicator
- Suppress "LIVE" dot entirely when offline
- News and earnings: show cached data with last-updated timestamp

---

## Market Hours Awareness

Suppress "LIVE" indicator when markets are closed:

```swift
struct MarketHours {
    static func isUSMarketOpen() -> Bool {
        let now = Date()
        let nyCalendar = Calendar(identifier: .gregorian)
        // Check weekday (Mon-Fri)
        // Check time (9:30 AM – 4:00 PM ET)
        // Check US market holidays (bundle holiday list)
        ...
    }
}
```

Bundle a `market-holidays.json` for US market holidays (update annually with tax rates JSON).
