import Foundation
import Combine

// MARK: - Historical Data Point

struct HistoricalDataPoint {
    let date: Date      // normalized to start of day
    let close: Double
}

// MARK: - Historical Price Service

@MainActor
final class HistoricalPriceService: ObservableObject {

    @Published private(set) var isLoading = false
    @Published private(set) var fetchError: String?

    // Cache keyed by "SYMBOL_days" — avoids re-fetching on range toggle
    private var cache: [String: [HistoricalDataPoint]] = [:]

    private let cryptoIDMap: [String: String]
    private let finnhubDelay: UInt64 = 120_000_000   // 120ms — safe under 60/min

    init() {
        cryptoIDMap = Self.loadCryptoIDMap()
    }

    // MARK: - Public API

    /// Fetches daily closing prices for each (symbol, source) pair for the last `days` days.
    /// Returns a dictionary of symbol → sorted [HistoricalDataPoint].
    /// Hits the cache first; only fetches missing symbols.
    func fetchHistory(
        symbols: [(symbol: String, source: PriceSource)],
        days: Int
    ) async -> [String: [HistoricalDataPoint]] {
        guard !symbols.isEmpty else { return [:] }
        isLoading = true
        fetchError = nil
        defer { isLoading = false }

        var result: [String: [HistoricalDataPoint]] = [:]
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -days, to: to) ?? to

        for item in symbols {
            let key = "\(item.symbol.uppercased())_\(days)"
            if let cached = cache[key] {
                result[item.symbol.uppercased()] = cached
                continue
            }

            let points: [HistoricalDataPoint]
            switch item.source {
            case .finnhub:
                points = await fetchFinnhub(symbol: item.symbol, from: from, to: to)
                try? await Task.sleep(nanoseconds: finnhubDelay)
            case .coingecko:
                points = await fetchCoinGecko(symbol: item.symbol, days: days)
            case .manual:
                points = []
            }

            if !points.isEmpty {
                cache[key] = points
                result[item.symbol.uppercased()] = points
            }
        }

        return result
    }

    func clearCache() { cache.removeAll() }

    // MARK: - Finnhub Daily Candles

    private func fetchFinnhub(symbol: String, from: Date, to: Date) async -> [HistoricalDataPoint] {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else {
            fetchError = "Finnhub API key not set."
            return []
        }

        var components = URLComponents(string: "https://finnhub.io/api/v1/stock/candle")!
        components.queryItems = [
            URLQueryItem(name: "symbol",     value: symbol.uppercased()),
            URLQueryItem(name: "resolution", value: "D"),
            URLQueryItem(name: "from",       value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "to",         value: String(Int(to.timeIntervalSince1970))),
            URLQueryItem(name: "token",      value: apiKey)
        ]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let candle = try JSONDecoder().decode(FinnhubCandle.self, from: data)
            guard candle.status == "ok",
                  candle.closes.count == candle.timestamps.count else { return [] }
            return zip(candle.timestamps, candle.closes).map { ts, close in
                HistoricalDataPoint(
                    date: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts))),
                    close: close
                )
            }
            .sorted { $0.date < $1.date }
        } catch {
            return []
        }
    }

    // MARK: - CoinGecko Market Chart

    private func fetchCoinGecko(symbol: String, days: Int) async -> [HistoricalDataPoint] {
        guard let coinId = cryptoIDMap[symbol.uppercased()] else { return [] }

        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/coins/\(coinId)/market_chart"
        )!
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days",        value: String(days)),
            URLQueryItem(name: "interval",    value: "daily")
        ]

        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let chart = try JSONDecoder().decode(CoinGeckoChart.self, from: data)
            return chart.prices.map { pair in
                HistoricalDataPoint(
                    date: Calendar.current.startOfDay(
                        for: Date(timeIntervalSince1970: pair[0] / 1000)
                    ),
                    close: pair[1]
                )
            }
            .sorted { $0.date < $1.date }
        } catch {
            return []
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

    private static let hardcodedCryptoMap: [String: String] = [
        "BTC": "bitcoin",   "ETH": "ethereum",  "SOL": "solana",
        "ADA": "cardano",   "MATIC": "matic-network", "DOT": "polkadot",
        "AVAX": "avalanche-2", "LINK": "chainlink", "UNI": "uniswap", "ATOM": "cosmos"
    ]
}

// MARK: - Lookup Helper

extension Array where Element == HistoricalDataPoint {
    /// Returns the closing price on or before the given date. Nil if no data exists.
    func price(on date: Date) -> Double? {
        let target = Calendar.current.startOfDay(for: date)
        return self.filter { $0.date <= target }.last?.close
    }
}

// MARK: - API Response Models (private)

private struct FinnhubCandle: Decodable {
    let closes:     [Double]
    let timestamps: [Int]
    let status:     String

    enum CodingKeys: String, CodingKey {
        case closes     = "c"
        case timestamps = "t"
        case status     = "s"
    }
}

private struct CoinGeckoChart: Decodable {
    let prices: [[Double]]
}
