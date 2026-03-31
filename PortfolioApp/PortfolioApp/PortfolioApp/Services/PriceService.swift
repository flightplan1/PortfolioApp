import Foundation
import Combine

// MARK: - Price Source

enum PriceSource: String, Codable {
    case finnhub
    case coingecko
    case manual
}

// MARK: - Price Data

struct PriceData {
    let symbol: String
    let currentPrice: Decimal
    let previousClosePrice: Decimal
    let openPrice: Decimal?
    let highPrice: Decimal?
    let lowPrice: Decimal?
    let fetchedAt: Date
    let source: PriceSource

    var dailyChange: Decimal {
        (currentPrice - previousClosePrice).rounded(to: 4)
    }

    var dailyChangePercent: Decimal {
        guard previousClosePrice > 0 else { return 0 }
        return ((dailyChange / previousClosePrice) * 100).rounded(to: 4)
    }

    var isStale: Bool { fetchedAt.isOlderThan15Minutes }

    var isLive: Bool { !isStale && Date.isUSMarketHours }
}

// MARK: - Price Service

@MainActor
final class PriceService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var prices: [String: PriceData] = [:]
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var fetchError: String?

    // MARK: - Private

    private var refreshTimer: Timer?
    private let cryptoIDMap: [String: String]

    // Finnhub rate limit: 60 calls/min, 30 calls/sec → 100ms between calls is safe.
    private let finnhubDelay: UInt64 = 100_000_000 // 100ms in nanoseconds

    // MARK: - Init

    init() {
        cryptoIDMap = Self.loadCryptoIDMap()
    }

    // MARK: - Public API

    func price(for symbol: String) -> PriceData? {
        prices[symbol.uppercased()]
    }

    func currentPrice(for symbol: String) -> Decimal? {
        prices[symbol.uppercased()]?.currentPrice
    }

    func dailyChange(for symbol: String) -> Decimal? {
        prices[symbol.uppercased()]?.dailyChange
    }

    func dailyChangePercent(for symbol: String) -> Decimal? {
        prices[symbol.uppercased()]?.dailyChangePercent
    }

    func isStale(for symbol: String) -> Bool {
        prices[symbol.uppercased()]?.isStale ?? true
    }

    func isLive(for symbol: String) -> Bool {
        prices[symbol.uppercased()]?.isLive ?? false
    }

    // MARK: - Refresh

    func refreshAllPrices(holdings: [Holding] = []) async {
        guard !isFetching else { return }
        isFetching = true
        fetchError = nil

        // Extract symbols before any async boundary — Holding is not Sendable
        let stockSymbols = holdings.filter { $0.priceSource == .finnhub }.map { $0.symbol }
        let cryptoSymbols = holdings.filter { $0.priceSource == .coingecko }.map { $0.symbol }

        // Seed $1.00 for manual-priced holdings (e.g. Cash) — no external fetch needed
        for h in holdings where h.priceSource == .manual {
            let sym = h.symbol.uppercased()
            prices[sym] = PriceData(symbol: sym, currentPrice: 1, previousClosePrice: 1,
                                    openPrice: 1, highPrice: 1, lowPrice: 1,
                                    fetchedAt: Date(), source: .manual)
        }

        await fetchPrices(stockSymbols: stockSymbols, cryptoSymbols: cryptoSymbols)

        lastFetchedAt = Date()
        isFetching = false
    }

    private func fetchPrices(stockSymbols: [String], cryptoSymbols: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            if !stockSymbols.isEmpty {
                group.addTask { [weak self] in
                    await self?.fetchFinnhubPrices(symbols: stockSymbols)
                }
            }
            if !cryptoSymbols.isEmpty {
                group.addTask { [weak self] in
                    await self?.fetchCoinGeckoPrices(symbols: cryptoSymbols)
                }
            }
        }
    }

    // MARK: - Timer

    func startAutoRefresh(holdings: [Holding]) {
        stopAutoRefresh()
        let stockSymbols = holdings.filter { $0.priceSource == .finnhub }.map { $0.symbol }
        let cryptoSymbols = holdings.filter { $0.priceSource == .coingecko }.map { $0.symbol }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchPrices(stockSymbols: stockSymbols, cryptoSymbols: cryptoSymbols)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Finnhub

    private func fetchFinnhubPrices(symbols: [String]) async {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else {
            fetchError = "Finnhub API key not set. Add your key in Settings."
            return
        }

        // Throttled sequential calls — never parallel (rate limit: 60/min)
        for symbol in symbols {
            await fetchFinnhubQuote(symbol: symbol, apiKey: apiKey)
            try? await Task.sleep(nanoseconds: finnhubDelay)
        }
    }

    private func fetchFinnhubQuote(symbol: String, apiKey: String) async {
        var components = URLComponents(string: "https://finnhub.io/api/v1/quote")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: symbol),
            URLQueryItem(name: "token", value: apiKey)
        ]

        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let quote = try JSONDecoder().decode(FinnhubQuote.self, from: data)
            guard quote.currentPrice > 0 else { return } // Market closed or invalid

            let priceData = PriceData(
                symbol: symbol.uppercased(),
                currentPrice: Decimal.from(quote.currentPrice),
                previousClosePrice: Decimal.from(quote.previousClose),
                openPrice: Decimal.from(quote.open),
                highPrice: Decimal.from(quote.high),
                lowPrice: Decimal.from(quote.low),
                fetchedAt: Date(),
                source: .finnhub
            )
            prices[symbol.uppercased()] = priceData
        } catch {
            print("Finnhub fetch error for \(symbol): \(error.localizedDescription)")
        }
    }

    // MARK: - CoinGecko

    private func fetchCoinGeckoPrices(symbols: [String]) async {
        // Map ticker symbols → CoinGecko IDs
        let idPairs = symbols.compactMap { symbol -> (symbol: String, id: String)? in
            guard let id = cryptoIDMap[symbol.uppercased()] else { return nil }
            return (symbol: symbol.uppercased(), id: id)
        }
        guard !idPairs.isEmpty else { return }

        let ids = idPairs.map { $0.id }.joined(separator: ",")
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true")
        ]

        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let result = try JSONDecoder().decode([String: CoinGeckoPrice].self, from: data)

            for pair in idPairs {
                guard let cgPrice = result[pair.id] else { continue }
                let current = Decimal.from(cgPrice.usd)
                let changePct = Decimal.from(cgPrice.usdChange ?? 0) / 100
                let previousClose = changePct == -1 ? 0 : (current / (1 + changePct)).rounded(to: 8)

                let priceData = PriceData(
                    symbol: pair.symbol,
                    currentPrice: current,
                    previousClosePrice: previousClose,
                    openPrice: nil,
                    highPrice: nil,
                    lowPrice: nil,
                    fetchedAt: Date(),
                    source: .coingecko
                )
                prices[pair.symbol] = priceData
            }
        } catch {
            print("CoinGecko fetch error: \(error.localizedDescription)")
        }
    }

    // MARK: - Crypto ID Map

    private static func loadCryptoIDMap() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "crypto-id-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return Self.hardcodedCryptoMap
        }
        return map
    }

    /// Fallback map if the JSON file isn't found (shouldn't happen in production).
    private static let hardcodedCryptoMap: [String: String] = [
        "BTC":   "bitcoin",
        "ETH":   "ethereum",
        "SOL":   "solana",
        "ADA":   "cardano",
        "MATIC": "matic-network",
        "DOT":   "polkadot",
        "AVAX":  "avalanche-2",
        "LINK":  "chainlink",
        "UNI":   "uniswap",
        "ATOM":  "cosmos"
    ]
}

// MARK: - API Response Models

private struct FinnhubQuote: Decodable {
    let currentPrice: Double
    let previousClose: Double
    let open: Double
    let high: Double
    let low: Double
    let change: Double
    let changePercent: Double

    enum CodingKeys: String, CodingKey {
        case currentPrice  = "c"
        case previousClose = "pc"
        case open          = "o"
        case high          = "h"
        case low           = "l"
        case change        = "d"
        case changePercent = "dp"
    }
}

private struct CoinGeckoPrice: Decodable {
    let usd: Double
    let usdChange: Double?

    enum CodingKeys: String, CodingKey {
        case usd        = "usd"
        case usdChange  = "usd_24h_change"
    }
}
