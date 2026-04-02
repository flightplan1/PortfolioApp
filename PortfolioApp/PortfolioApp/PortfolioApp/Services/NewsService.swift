import Foundation
import Combine

// MARK: - NewsArticle
// Represents a single news article from Finnhub.
// Used for both company-specific news and general market news.

struct NewsArticle: Identifiable, Equatable {
    let id: Int           // Finnhub article ID
    let headline: String
    let summary: String
    let source: String
    let url: URL?
    let imageURL: URL?
    let publishedAt: Date
    let relatedSymbols: [String]  // symbols mentioned (from company news calls)

    static func == (lhs: NewsArticle, rhs: NewsArticle) -> Bool { lhs.id == rhs.id }
}

// MARK: - NewsService
// Fetches company news (per holding symbol) and general market news from Finnhub.
// Caches results in memory; re-fetches when stale (> 15 minutes old).
// Rate limit: 60 calls/min → 150ms between calls.

final class NewsService: ObservableObject {

    static let shared = NewsService()
    private init() {}

    // MARK: - Published State

    /// Merged, deduplicated articles sorted newest-first.
    @Published private(set) var articles: [NewsArticle] = []
    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: String? = nil

    // MARK: - Private

    private var lastFetchedAt: Date? = nil
    private let staleInterval: TimeInterval = 15 * 60  // 15 minutes

    // MARK: - Public API

    /// Fetches news for the given symbols + general market news.
    /// Skips if data is less than 15 minutes old.
    func fetchIfNeeded(symbols: [String]) async {
        if let last = lastFetchedAt, Date().timeIntervalSince(last) < staleInterval { return }
        await fetch(symbols: symbols)
    }

    /// Force-refresh regardless of cache age.
    func fetch(symbols: [String]) async {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return }

        await MainActor.run { isFetching = true; fetchError = nil }

        var collected: [NewsArticle] = []
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let from = isoDateString(sevenDaysAgo)
        let to   = isoDateString(Date())

        // Company news — one call per stock/ETF symbol
        let stockSymbols = symbols.filter { !$0.isEmpty }
        for symbol in stockSymbols {
            if let news = await fetchCompanyNews(symbol: symbol, from: from, to: to, apiKey: apiKey) {
                collected.append(contentsOf: news)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // General market news
        if let market = await fetchMarketNews(apiKey: apiKey) {
            collected.append(contentsOf: market)
        }

        // Deduplicate by id, sort newest-first
        var seen = Set<Int>()
        let deduped = collected.filter { seen.insert($0.id).inserted }
            .sorted { $0.publishedAt > $1.publishedAt }

        await MainActor.run {
            articles = deduped
            isFetching = false
            lastFetchedAt = Date()
        }
    }

    // MARK: - Finnhub: Company News

    private struct FinnhubArticle: Decodable {
        let id: Int
        let headline: String
        let summary: String
        let source: String
        let url: String
        let image: String
        let datetime: TimeInterval
        let related: String
    }

    private func fetchCompanyNews(symbol: String, from: String, to: String, apiKey: String) async -> [NewsArticle]? {
        let urlStr = "https://finnhub.io/api/v1/company-news?symbol=\(symbol)&from=\(from)&to=\(to)&token=\(apiKey)"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = try JSONDecoder().decode([FinnhubArticle].self, from: data)
            return raw.prefix(10).map { map($0, symbols: [symbol]) }
        } catch {
            return nil
        }
    }

    // MARK: - Finnhub: Market News

    private struct FinnhubMarketArticle: Decodable {
        let id: Int
        let headline: String
        let summary: String
        let source: String
        let url: String
        let image: String
        let datetime: TimeInterval
    }

    private func fetchMarketNews(apiKey: String) async -> [NewsArticle]? {
        let urlStr = "https://finnhub.io/api/v1/news?category=general&token=\(apiKey)"
        guard let url = URL(string: urlStr) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let raw = try JSONDecoder().decode([FinnhubMarketArticle].self, from: data)
            return raw.prefix(20).map { article in
                NewsArticle(
                    id: article.id,
                    headline: article.headline,
                    summary: article.summary,
                    source: article.source,
                    url: URL(string: article.url),
                    imageURL: URL(string: article.image),
                    publishedAt: Date(timeIntervalSince1970: article.datetime),
                    relatedSymbols: []
                )
            }
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func map(_ a: FinnhubArticle, symbols: [String]) -> NewsArticle {
        NewsArticle(
            id: a.id,
            headline: a.headline,
            summary: a.summary,
            source: a.source,
            url: URL(string: a.url),
            imageURL: URL(string: a.image),
            publishedAt: Date(timeIntervalSince1970: a.datetime),
            relatedSymbols: symbols
        )
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
