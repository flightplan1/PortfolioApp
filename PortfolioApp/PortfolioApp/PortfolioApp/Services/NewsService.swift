import Foundation
import Combine
import UserNotifications

// MARK: - NewsArticle
// Represents a single news article from Finnhub.
// Used for both company-specific news and general market news.

enum NewsSentiment: String {
    case positive, negative, neutral
}

struct NewsArticle: Identifiable, Equatable {
    let id: Int           // Finnhub article ID
    let headline: String
    let summary: String
    let source: String
    let url: URL?
    let imageURL: URL?
    let publishedAt: Date
    let relatedSymbols: [String]  // symbols mentioned (from company news calls)
    let sentiment: NewsSentiment  // keyword-derived

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

    // Breaking news notification throttle — max 3 per day
    private let breakingNewsCountKey = "breaking_news_count_v1"
    private let breakingNewsDateKey  = "breaking_news_date_v1"
    private let breakingNewsLimit    = 3

    private var seenArticleIds: Set<Int> = []

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
                    relatedSymbols: [],
                    sentiment: deriveSentiment(headline: article.headline)
                )
            }
        } catch {
            return nil
        }
    }

    // MARK: - Breaking News Notifications

    /// Sends a local notification for a new article if under today's throttle limit.
    func sendBreakingNewsNotificationIfAllowed(for article: NewsArticle, prefs: NotificationPreferencesManager) async {
        guard prefs.breakingNewsAlertsEnabled else { return }

        let ud = UserDefaults.standard
        let todayStr = isoDateString(Date())
        let storedDate  = ud.string(forKey: breakingNewsDateKey) ?? ""
        let storedCount = storedDate == todayStr ? (ud.integer(forKey: breakingNewsCountKey)) : 0
        guard storedCount < breakingNewsLimit else { return }

        let content = UNMutableNotificationContent()
        content.title = article.relatedSymbols.first.map { "\($0) — Breaking News" } ?? "Market News"
        content.body  = article.headline
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "breaking_\(article.id)",
            content: content,
            trigger: nil   // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)

        ud.set(todayStr, forKey: breakingNewsDateKey)
        ud.set(storedCount + 1, forKey: breakingNewsCountKey)
    }

    /// Call from background fetch handler: notify for articles not seen in the previous fetch.
    func notifyNewArticles(prefs: NotificationPreferencesManager) async {
        for article in articles where !seenArticleIds.contains(article.id) {
            await sendBreakingNewsNotificationIfAllowed(for: article, prefs: prefs)
            seenArticleIds.insert(article.id)
        }
    }

    // MARK: - Sentiment

    /// Derives sentiment from the article headline using keyword matching.
    private func deriveSentiment(headline: String) -> NewsSentiment {
        let lower = headline.lowercased()
        let negativeWords = [
            "fall", "falls", "fell", "drop", "drops", "dropped", "decline", "declines",
            "loss", "losses", "crash", "crashes", "plunge", "plunges", "slump", "slumps",
            "miss", "misses", "missed", "cut", "cuts", "layoff", "layoffs", "recall",
            "fraud", "investigation", "fine", "penalty", "warning", "risk", "concern",
            "downgrade", "disappoints", "disappointing", "weak", "below expectations",
            "sell-off", "selloff", "bearish", "bankruptcy", "default", "debt"
        ]
        let positiveWords = [
            "rise", "rises", "rose", "gain", "gains", "gained", "surge", "surges",
            "beat", "beats", "record", "profit", "profits", "upgrade", "growth",
            "deal", "acquisition", "partnership", "exceeds", "above expectations",
            "bullish", "strong", "soar", "soars", "rally", "rallies", "breakthrough"
        ]
        let isNegative = negativeWords.contains { lower.contains($0) }
        let isPositive = positiveWords.contains { lower.contains($0) }
        if isNegative && !isPositive { return .negative }
        if isPositive && !isNegative { return .positive }
        return .neutral
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
            relatedSymbols: symbols,
            sentiment: deriveSentiment(headline: a.headline)
        )
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
