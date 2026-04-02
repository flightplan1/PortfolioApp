import SwiftUI
import CoreData

// MARK: - NewsView
// The News tab. Shows:
//   1. Upcoming earnings for held stocks (next 90 days)
//   2. News articles — filterable by symbol or "All"
// Both sections powered by NewsService + EarningsService singletons.

struct NewsView: View {

    @EnvironmentObject private var priceService: PriceService
    @Environment(\.managedObjectContext) private var context

    @FetchRequest(
        fetchRequest: Holding.allActiveRequest(),
        animation: .none
    ) private var holdings: FetchedResults<Holding>

    // Open lots — used to determine which holdings are still actively held
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isClosed == NO AND isSoftDeleted == NO"),
        animation: .none
    ) private var openLots: FetchedResults<Lot>

    @ObservedObject private var newsService     = NewsService.shared
    @ObservedObject private var earningsService = EarningsService.shared

    @State private var selectedSymbol: String? = nil  // nil = All
    @State private var showEarnings = true

    // MARK: - Computed

    private var activeHoldingIds: Set<UUID> {
        Set(openLots.map { $0.holdingId })
    }

    private var stockSymbols: [String] {
        holdings
            .filter {
                ($0.assetType == .stock || $0.assetType == .etf)
                && activeHoldingIds.contains($0.id)
            }
            .map { $0.symbol }
            .sorted()
    }

    private var filteredArticles: [NewsArticle] {
        guard let sym = selectedSymbol else { return newsService.articles }
        return newsService.articles.filter { $0.relatedSymbols.contains(sym) }
    }

    private var upcomingEarnings: [EarningsEvent] {
        earningsService.upcomingEvents()
            .filter { stockSymbols.contains($0.symbol) }
            .prefix(10)
            .map { $0 }
    }

    private var recentEarnings: [EarningsEvent] {
        earningsService.recentEvents()
            .filter { stockSymbols.contains($0.symbol) }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()
                if newsService.isFetching && newsService.articles.isEmpty {
                    loadingState
                } else if newsService.articles.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("News & Earnings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if newsService.isFetching {
                        ProgressView().tint(.appBlue)
                    } else {
                        Button {
                            Task { await newsService.fetch(symbols: stockSymbols) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.appBlue)
                        }
                    }
                }
            }
            .task {
                async let news: () = newsService.fetchIfNeeded(symbols: stockSymbols)
                async let earnings: () = earningsService.fetchIfNeeded(symbols: stockSymbols)
                await news
                await earnings
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Symbol filter chips
                if !stockSymbols.isEmpty {
                    symbolFilterRow
                }

                // Earnings section (only for All or when a symbol has earnings)
                let hasEarnings = !upcomingEarnings.isEmpty || !recentEarnings.isEmpty
                if hasEarnings && selectedSymbol == nil {
                    earningsSection
                }

                // News articles
                newsSection
            }
            .padding(16)
        }
    }

    // MARK: - Symbol Filter Row

    private var symbolFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", symbol: nil)
                ForEach(stockSymbols, id: \.self) { sym in
                    filterChip(label: sym, symbol: sym)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private func filterChip(label: String, symbol: String?) -> some View {
        let isSelected = selectedSymbol == symbol
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedSymbol = symbol }
        } label: {
            Text(label)
                .font(AppFont.mono(12, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : .textSub)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.appBlue : Color.surface)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSelected ? Color.clear : Color.appBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Earnings Section

    private var earningsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showEarnings.toggle() }
            } label: {
                HStack {
                    Text("EARNINGS CALENDAR")
                        .sectionTitleStyle()
                    Spacer()
                    Image(systemName: showEarnings ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if showEarnings {
                VStack(spacing: 0) {
                    if !upcomingEarnings.isEmpty {
                        earningsSectionHeader("UPCOMING")
                        ForEach(Array(upcomingEarnings.enumerated()), id: \.element.id) { index, event in
                            EarningsEventRow(event: event)
                            if index < upcomingEarnings.count - 1 {
                                Divider().background(Color.appBorder)
                            }
                        }
                    }

                    if !recentEarnings.isEmpty {
                        if !upcomingEarnings.isEmpty {
                            Divider().background(Color.appBorder)
                        }
                        earningsSectionHeader("RECENT")
                        ForEach(Array(recentEarnings.enumerated()), id: \.element.id) { index, event in
                            EarningsEventRow(event: event)
                            if index < recentEarnings.count - 1 {
                                Divider().background(Color.appBorder)
                            }
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    private func earningsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.mono(10, weight: .bold))
            .foregroundColor(.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    // MARK: - News Section

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedSymbol.map { "\($0) NEWS" } ?? "MARKET NEWS")
                    .sectionTitleStyle()
                Spacer()
                Text("\(filteredArticles.count) articles")
                    .font(AppFont.mono(10))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 4)

            if filteredArticles.isEmpty {
                Text("No articles found for this symbol.")
                    .font(AppFont.body(13))
                    .foregroundColor(.textMuted)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredArticles.enumerated()), id: \.element.id) { index, article in
                        NewsArticleRow(article: article)
                        if index < filteredArticles.count - 1 {
                            Divider().background(Color.appBorder)
                        }
                    }
                }
                .cardStyle()
            }
        }
    }

    // MARK: - Loading / Empty

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.appBlue)
            Text("Loading news…")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 36))
                .foregroundColor(.textMuted)
            Text("No news available")
                .font(AppFont.body(15, weight: .semibold))
                .foregroundColor(.textSub)
            Text("Add stock or ETF holdings to see news.")
                .font(AppFont.body(13))
                .foregroundColor(.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

// MARK: - News Article Row

struct NewsArticleRow: View {
    let article: NewsArticle

    var body: some View {
        Button {
            if let url = article.url {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    // Symbol tags
                    if !article.relatedSymbols.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(article.relatedSymbols.prefix(3), id: \.self) { sym in
                                Text(sym)
                                    .font(AppFont.mono(9, weight: .bold))
                                    .foregroundColor(.appBlue)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.appBlue.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }

                    Text(article.headline)
                        .font(AppFont.body(13, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        Text(article.source)
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                        Text("·")
                            .foregroundColor(.textMuted)
                        Text(article.publishedAt.timeAgoString)
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.textMuted)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Earnings Event Row

struct EarningsEventRow: View {
    let event: EarningsEvent

    var body: some View {
        HStack(spacing: 12) {
            // Symbol + date column
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(event.symbol)
                        .font(AppFont.mono(13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if !event.quarter.isEmpty {
                        Text(event.quarter)
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                    }
                }
                Text(event.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.mono(11))
                    .foregroundColor(.textSub)
            }

            Spacer()

            // EPS column
            VStack(alignment: .trailing, spacing: 4) {
                if let actual = event.epsActual {
                    HStack(spacing: 4) {
                        if let beat = event.beat {
                            Image(systemName: beat ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(beat ? .appGreen : .appRed)
                        }
                        Text("$\(actual.asQuantity(maxDecimalPlaces: 2))")
                            .font(AppFont.mono(12, weight: .semibold))
                            .foregroundColor(.textPrimary)
                    }
                    if let est = event.epsEstimate {
                        Text("est $\(est.asQuantity(maxDecimalPlaces: 2))")
                            .font(AppFont.mono(10))
                            .foregroundColor(.textMuted)
                    }
                } else if let est = event.epsEstimate {
                    Text("est $\(est.asQuantity(maxDecimalPlaces: 2))")
                        .font(AppFont.mono(12, weight: .semibold))
                        .foregroundColor(.textSub)
                    Text("EPS estimate")
                        .font(AppFont.mono(10))
                        .foregroundColor(.textMuted)
                } else {
                    Text(event.isUpcoming ? "Upcoming" : "Reported")
                        .font(AppFont.mono(11))
                        .foregroundColor(.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Date Extension

private extension Date {
    var timeAgoString: String {
        let diff = Int(Date().timeIntervalSince(self))
        if diff < 3600  { return "\(diff / 60)m ago" }
        if diff < 86400 { return "\(diff / 3600)h ago" }
        return "\(diff / 86400)d ago"
    }
}
