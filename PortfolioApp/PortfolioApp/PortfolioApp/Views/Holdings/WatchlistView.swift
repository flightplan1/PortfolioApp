import SwiftUI
import CoreData

// MARK: - Watchlist View

struct WatchlistView: View {

    @ObservedObject private var watchlist = WatchlistManager.shared
    @EnvironmentObject private var priceService: PriceService

    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .none)
    private var holdings: FetchedResults<Holding>

    @State private var addSymbolText = ""
    @State private var isAddingSymbol = false
    @State private var editMode: EditMode = .inactive

    private var heldSymbols: Set<String> {
        Set(holdings.map { $0.symbol.uppercased() })
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if watchlist.symbols.isEmpty && !isAddingSymbol {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        // Add symbol input
                        addSymbolRow
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 12)

                        if !watchlist.symbols.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(watchlist.symbols.enumerated()), id: \.element) { index, symbol in
                                    if index > 0 { Divider().background(Color.appBorder) }
                                    watchlistRow(symbol: symbol)
                                }
                            }
                            .cardStyle()
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .font(AppFont.body(14))
                    .foregroundColor(.appBlue)
            }
        }
        .environment(\.editMode, $editMode)
        .onDisappear { isAddingSymbol = false }
    }

    // MARK: - Add Symbol Row

    private var addSymbolRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.appBlue)

            if isAddingSymbol {
                TextField("Ticker symbol (e.g. AAPL)", text: $addSymbolText)
                    .font(AppFont.mono(14))
                    .foregroundColor(.textPrimary)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .onSubmit { commitAdd() }

                if !addSymbolText.isEmpty {
                    Button("Add") { commitAdd() }
                        .font(AppFont.body(13, weight: .semibold))
                        .foregroundColor(.appBlue)
                }

                Button("Cancel") {
                    addSymbolText = ""
                    isAddingSymbol = false
                }
                .font(AppFont.body(13))
                .foregroundColor(.textMuted)

            } else {
                Button("Add symbol to watchlist") {
                    isAddingSymbol = true
                }
                .font(AppFont.body(14))
                .foregroundColor(.appBlue)
                Spacer()
            }
        }
        .padding(14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            isAddingSymbol ? Color.appBlue.opacity(0.5) : Color.appBorder, lineWidth: 1)
        )
    }

    private func commitAdd() {
        let sym = addSymbolText.trimmingCharacters(in: .whitespaces).uppercased()
        guard !sym.isEmpty else { return }
        watchlist.add(sym)
        addSymbolText = ""
        isAddingSymbol = false
    }

    // MARK: - Watchlist Row

    private func watchlistRow(symbol: String) -> some View {
        let priceData = priceService.price(for: symbol)
        let isHeld = heldSymbols.contains(symbol)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(symbol)
                        .font(AppFont.mono(15, weight: .bold))
                        .foregroundColor(.textPrimary)
                    if isHeld {
                        Text("HELD")
                            .font(AppFont.mono(8, weight: .bold))
                            .foregroundColor(.appGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.appGreenDim)
                            .clipShape(Capsule())
                    }
                }
                if let node = IndustryGraphLoader.company(for: symbol), !node.industry.isEmpty {
                    Text(node.industry)
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
            }

            Spacer()

            if let price = priceData {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(price.currentPrice.asCurrency)
                        .font(AppFont.mono(15, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    HStack(spacing: 4) {
                        Image(systemName: price.dailyChange >= 0 ? "arrow.up" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%.2f%%", abs((price.dailyChangePercent as NSDecimalNumber).doubleValue)))
                            .font(AppFont.mono(11))
                    }
                    .foregroundColor(price.dailyChange >= 0 ? .appGreen : .appRed)
                }
            } else {
                Text("—")
                    .font(AppFont.mono(14))
                    .foregroundColor(.textMuted)
            }

            if editMode == .active {
                Button {
                    withAnimation { watchlist.remove(symbol) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.appRed)
                        .font(.system(size: 20))
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye")
                .font(.system(size: 52))
                .foregroundColor(.textMuted)
            Text("No Symbols Watched")
                .font(AppFont.body(18, weight: .semibold))
                .foregroundColor(.textPrimary)
            Text("Add tickers to track price and news\nwithout adding them to your portfolio.")
                .font(AppFont.body(14))
                .foregroundColor(.textMuted)
                .multilineTextAlignment(.center)
            Button {
                isAddingSymbol = true
            } label: {
                Text("Add Symbol")
                    .font(AppFont.body(14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.appBlue)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
    }
}
