import SwiftUI
import CoreData

// MARK: - IndustryDetailCard
// Single code path for all symbols:
//   - Static graph entry (industry-graph.json): shows upstream/downstream chains.
//   - Dynamic entry (user-graph.json via Finnhub): shows industry info + peer group.
//   - Not yet fetched: triggers a just-in-time fetch via DynamicGraphService.

struct IndustryDetailCard: View {

    let symbol: String

    @FetchRequest(fetchRequest: Holding.allActiveRequest(), animation: .none)
    private var allHoldings: FetchedResults<Holding>

    // Observing isSyncing triggers a re-render when DynamicGraphService completes a fetch,
    // causing `node` to re-evaluate and pick up the newly written user-graph entry.
    @ObservedObject private var dynamicGraph = DynamicGraphService.shared
    @State private var isLoadingJIT: Bool = false

    // MARK: - Computed

    private var heldSymbols: Set<String> {
        Set(allHoldings.map { $0.symbol })
    }

    /// Checks static graph first, then user-graph.json (via DynamicGraphService write).
    private var node: CompanyNode? {
        IndustryGraphLoader.company(for: symbol)
    }

    private var upstreamNodes: [CompanyNode] {
        IndustryGraphLoader.upstreamNodes(for: symbol)
    }

    private var downstreamNodes: [CompanyNode] {
        IndustryGraphLoader.downstreamNodes(for: symbol)
    }

    private var downstreamSectorCounts: [(sector: String, name: String, count: Int, hex: String)] {
        var counts: [String: Int] = [:]
        for n in downstreamNodes { counts[n.sector, default: 0] += 1 }
        let graph = IndustryGraphLoader.load()
        let sectorNames  = Dictionary(uniqueKeysWithValues: graph.sectors.map { ($0.key, $0.name) })
        let sectorColors = Dictionary(uniqueKeysWithValues: graph.sectors.map { ($0.key, $0.color) })
        return counts
            .sorted { $0.value > $1.value }
            .map { (sector: $0.key,
                    name: sectorNames[$0.key] ?? $0.key.capitalized,
                    count: $0.value,
                    hex: sectorColors[$0.key] ?? "#888888") }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INDUSTRY")
                .sectionTitleStyle()
                .padding(.horizontal, 4)

            if let node = node {
                nodeContent(node)
            } else if isLoadingJIT || dynamicGraph.isSyncing {
                loadingCard
            } else {
                noDataCard
            }
        }
        .task { await loadIfNeeded() }
    }

    // MARK: - Node Content (unified path)

    @ViewBuilder
    private func nodeContent(_ node: CompanyNode) -> some View {
        // Header card
        if node.isDynamic {
            dynamicHeaderCard(node)
        } else {
            staticSectorCard(node)
        }

        // Supply chain (static entries)
        if !upstreamNodes.isEmpty {
            dependencyCard(title: "UPSTREAM SUPPLIERS",
                           subtitle: "Companies this stock depends on",
                           nodes: upstreamNodes,
                           arrowName: "arrow.up.circle.fill",
                           arrowColor: .appBlue)
        }
        if !downstreamNodes.isEmpty {
            dependencyCard(title: "DOWNSTREAM CUSTOMERS",
                           subtitle: "Companies that depend on this stock",
                           nodes: downstreamNodes,
                           arrowName: "arrow.down.circle.fill",
                           arrowColor: .appGreen)
            if downstreamSectorCounts.count > 1 {
                sectorExposureCard
            }
        }
        if !node.isDynamic && upstreamNodes.isEmpty && downstreamNodes.isEmpty {
            FormCard(title: "SUPPLY CHAIN") {
                Text("No dependency data available for \(symbol).")
                    .font(AppFont.body(13))
                    .foregroundColor(.textMuted)
                    .padding(16)
            }
        }

        // Peer group (dynamic/Finnhub entries)
        if node.isDynamic && !node.peers.isEmpty {
            peersCard(peers: node.peers)
        }
    }

    // MARK: - JIT Load

    private func loadIfNeeded() async {
        guard node == nil else { return }
        isLoadingJIT = true
        await DynamicGraphService.shared.fetchAndStore(symbol: symbol)
        isLoadingJIT = false
    }

    // MARK: - Header Cards

    private func staticSectorCard(_ node: CompanyNode) -> some View {
        let graph = IndustryGraphLoader.load()
        let hex        = graph.sectors.first { $0.key == node.sector }?.color ?? "#888888"
        let sectorName = graph.sectors.first { $0.key == node.sector }?.name ?? node.sector.capitalized
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(AppFont.body(14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 8) {
                    sectorPill(sectorName, hex: hex)
                    industryPill(node.industry)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
    }

    private func dynamicHeaderCard(_ node: CompanyNode) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(AppFont.body(14, weight: .semibold))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 8) {
                    if !node.industry.isEmpty { industryPill(node.industry) }
                }
            }
            Spacer()
            Text("FINNHUB")
                .font(AppFont.mono(8, weight: .bold))
                .foregroundColor(.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.surfaceAlt)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.appBorder, lineWidth: 1))
    }

    // MARK: - Pills

    private func sectorPill(_ name: String, hex: String) -> some View {
        Text(name)
            .font(AppFont.mono(10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(hex: hex))
            .clipShape(Capsule())
    }

    private func industryPill(_ name: String) -> some View {
        Text(name)
            .font(AppFont.mono(10))
            .foregroundColor(.textSub)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.surfaceAlt)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
    }

    // MARK: - Dependency Card (static)

    private func dependencyCard(
        title: String,
        subtitle: String,
        nodes: [CompanyNode],
        arrowName: String,
        arrowColor: Color
    ) -> some View {
        FormCard(title: title) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: arrowName)
                        .font(.system(size: 11))
                        .foregroundColor(arrowColor)
                    Text(subtitle)
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ForEach(Array(nodes.enumerated()), id: \.element.id) { index, n in
                    if index > 0 { Divider().background(Color.appBorder) }
                    companyRow(n)
                }
            }
        }
    }

    private func companyRow(_ node: CompanyNode) -> some View {
        let isHeld = heldSymbols.contains(node.symbol)
        let graph = IndustryGraphLoader.load()
        let hex = graph.sectors.first { $0.key == node.sector }?.color ?? "#888888"
        return HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.symbol)
                    .font(AppFont.mono(13, weight: .bold))
                    .foregroundColor(.textPrimary)
                Text(node.name)
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            if isHeld {
                Text("IN PORTFOLIO")
                    .font(AppFont.mono(9, weight: .bold))
                    .foregroundColor(.appGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appGreenDim)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Peers Card (dynamic)

    private func peersCard(peers: [String]) -> some View {
        FormCard(title: "RELATED COMPANIES") {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.appBlue)
                    Text("Companies in the same industry peer group")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                ForEach(Array(peers.prefix(10).enumerated()), id: \.element) { index, peer in
                    if index > 0 { Divider().background(Color.appBorder) }
                    peerRow(peer)
                }
                if peers.count > 10 {
                    Divider().background(Color.appBorder)
                    Text("+\(peers.count - 10) more")
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func peerRow(_ peerSymbol: String) -> some View {
        let isHeld = heldSymbols.contains(peerSymbol)
        // Check if peer also has a node so we can show its name
        let peerNode = IndustryGraphLoader.company(for: peerSymbol)
        return HStack(spacing: 10) {
            Circle()
                .fill(Color.appBlue.opacity(0.6))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(peerSymbol)
                    .font(AppFont.mono(13, weight: .bold))
                    .foregroundColor(.textPrimary)
                if let name = peerNode?.name {
                    Text(name)
                        .font(AppFont.body(11))
                        .foregroundColor(.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isHeld {
                Text("IN PORTFOLIO")
                    .font(AppFont.mono(9, weight: .bold))
                    .foregroundColor(.appGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.appGreenDim)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Sector Exposure Chart (static)

    private var sectorExposureCard: some View {
        FormCard(title: "DOWNSTREAM SECTOR EXPOSURE") {
            VStack(spacing: 0) {
                Text("Sector breakdown of companies that depend on \(symbol)")
                    .font(AppFont.body(11))
                    .foregroundColor(.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                let total = downstreamSectorCounts.reduce(0) { $0 + $1.count }
                ForEach(downstreamSectorCounts, id: \.sector) { entry in
                    let pct = total > 0 ? Double(entry.count) / Double(total) : 0
                    sectorExposureRow(entry: entry, pct: pct)
                    if entry.sector != downstreamSectorCounts.last?.sector {
                        Divider().background(Color.appBorder)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func sectorExposureRow(entry: (sector: String, name: String, count: Int, hex: String), pct: Double) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(AppFont.body(12))
                    .foregroundColor(.textSub)
                Spacer()
                Text("\(entry.count) co.")
                    .font(AppFont.mono(11))
                    .foregroundColor(.textMuted)
                Text(String(format: "%.0f%%", pct * 100))
                    .font(AppFont.mono(11, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .frame(width: 36, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.surfaceAlt).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: entry.hex))
                        .frame(width: geo.size.width * pct, height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - States

    private var loadingCard: some View {
        FormCard(title: "INDUSTRY") {
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8)
                Text("Loading industry data…")
                    .font(AppFont.body(13))
                    .foregroundColor(.textMuted)
            }
            .padding(16)
        }
    }

    private var noDataCard: some View {
        FormCard(title: "INDUSTRY") {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.textMuted)
                Text("No industry data available for \(symbol). Check your Finnhub API key in Settings.")
                    .font(AppFont.body(12))
                    .foregroundColor(.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }
}
