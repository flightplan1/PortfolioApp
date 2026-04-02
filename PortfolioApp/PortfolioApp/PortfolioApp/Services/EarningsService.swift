import Foundation
import Combine

// MARK: - EarningsEvent
// A single earnings report entry from Finnhub's earnings calendar.

struct EarningsEvent: Identifiable {
    let id: String          // "\(symbol)_\(date)"
    let symbol: String
    let date: Date
    let epsEstimate: Decimal?
    let epsActual: Decimal?
    let revenueEstimate: Decimal?
    let revenueActual: Decimal?
    let quarter: String     // e.g. "Q1 2025"

    var isUpcoming: Bool { date >= Calendar.current.startOfDay(for: Date()) }

    var epsSurprise: Decimal? {
        guard let actual = epsActual, let estimate = epsEstimate, estimate != 0 else { return nil }
        return ((actual - estimate) / abs(estimate) * 100).rounded(to: 1)
    }

    var beat: Bool? {
        guard let actual = epsActual, let estimate = epsEstimate else { return nil }
        return actual >= estimate
    }
}

// MARK: - EarningsService
// Fetches earnings calendar from Finnhub for all held stock/ETF symbols.
// Looks 90 days back and 90 days forward. Caches in memory; stale after 6 hours.

final class EarningsService: ObservableObject {

    static let shared = EarningsService()
    private init() {}

    // MARK: - Published State

    @Published private(set) var events: [EarningsEvent] = []
    @Published private(set) var isFetching = false

    // MARK: - Private

    private var lastFetchedAt: Date? = nil
    private let staleInterval: TimeInterval = 6 * 60 * 60  // 6 hours

    // MARK: - Public API

    func fetchIfNeeded(symbols: [String]) async {
        if let last = lastFetchedAt, Date().timeIntervalSince(last) < staleInterval { return }
        await fetch(symbols: symbols)
    }

    func fetch(symbols: [String]) async {
        guard let apiKey = try? APIKeyManager.getFinnhubKey() else { return }
        guard !symbols.isEmpty else { return }

        await MainActor.run { isFetching = true }

        let from = isoDateString(Calendar.current.date(byAdding: .day, value: -90, to: Date())!)
        let to   = isoDateString(Calendar.current.date(byAdding: .day, value:  90, to: Date())!)

        // Finnhub earnings calendar supports comma-separated symbols in one call
        let symbolList = symbols.prefix(20).joined(separator: ",")
        let urlStr = "https://finnhub.io/api/v1/calendar/earnings?from=\(from)&to=\(to)&symbol=\(symbolList)&token=\(apiKey)"

        var collected: [EarningsEvent] = []

        if let url = URL(string: urlStr) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(FinnhubEarningsResponse.self, from: data)
                collected = response.earningsCalendar.compactMap { map($0) }
            } catch {}
        }

        // If more than 20 symbols, batch remaining with 150ms delays
        if symbols.count > 20 {
            for symbol in symbols.dropFirst(20) {
                let singleUrl = "https://finnhub.io/api/v1/calendar/earnings?from=\(from)&to=\(to)&symbol=\(symbol)&token=\(apiKey)"
                if let url = URL(string: singleUrl) {
                    if let (data, _) = try? await URLSession.shared.data(from: url),
                       let response = try? JSONDecoder().decode(FinnhubEarningsResponse.self, from: data) {
                        collected.append(contentsOf: response.earningsCalendar.compactMap { map($0) })
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        let sorted = collected.sorted { $0.date < $1.date }

        await MainActor.run {
            events = sorted
            isFetching = false
            lastFetchedAt = Date()
        }
    }

    // MARK: - Computed Helpers

    func upcomingEvents(for symbol: String? = nil) -> [EarningsEvent] {
        let today = Calendar.current.startOfDay(for: Date())
        return events.filter {
            $0.date >= today && (symbol == nil || $0.symbol == symbol)
        }
    }

    func recentEvents(for symbol: String? = nil) -> [EarningsEvent] {
        let today = Calendar.current.startOfDay(for: Date())
        return events.filter {
            $0.date < today && (symbol == nil || $0.symbol == symbol)
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Finnhub Decodable

    private struct FinnhubEarningsResponse: Decodable {
        let earningsCalendar: [FinnhubEarning]
    }

    private struct FinnhubEarning: Decodable {
        let symbol: String
        let date: String
        let epsEstimate: Decimal?
        let epsActual: Decimal?
        let revenueEstimate: Decimal?
        let revenueActual: Decimal?
        let quarter: Int?
        let year: Int?

        enum CodingKeys: String, CodingKey {
            case symbol, date, epsEstimate, epsActual, revenueEstimate, revenueActual, quarter, year
        }
    }

    private func map(_ e: FinnhubEarning) -> EarningsEvent? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        guard let date = formatter.date(from: e.date) else { return nil }

        let quarterStr: String
        if let q = e.quarter, let y = e.year {
            quarterStr = "Q\(q) \(y)"
        } else {
            quarterStr = ""
        }

        return EarningsEvent(
            id: "\(e.symbol)_\(e.date)",
            symbol: e.symbol,
            date: date,
            epsEstimate: e.epsEstimate,
            epsActual: e.epsActual,
            revenueEstimate: e.revenueEstimate,
            revenueActual: e.revenueActual,
            quarter: quarterStr
        )
    }

    private func isoDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
