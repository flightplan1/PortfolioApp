import SwiftUI
import CoreData

struct ContentView: View {

    @EnvironmentObject private var networkMonitor:        NetworkMonitor
    @EnvironmentObject private var priceService:          PriceService
    @EnvironmentObject private var taxProfileManager:     TaxProfileManager
    @EnvironmentObject private var remoteTaxRatesService: RemoteTaxRatesService

    @State private var selectedTab:      Tab  = .holdings
    @State private var showTaxOnboarding: Bool = false

    enum Tab: Int, CaseIterable {
        case dashboard, holdings, pnl, news, settings

        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .holdings:  return "Holdings"
            case .pnl:       return "P&L"
            case .news:      return "News"
            case .settings:  return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .dashboard: return "square.grid.2x2"
            case .holdings:  return "briefcase"
            case .pnl:       return "chart.bar"
            case .news:      return "newspaper"
            case .settings:  return "gearshape"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tabItem { Label(Tab.dashboard.title, systemImage: Tab.dashboard.systemImage) }
                    .tag(Tab.dashboard)

                HoldingsListView()
                    .tabItem { Label(Tab.holdings.title, systemImage: Tab.holdings.systemImage) }
                    .tag(Tab.holdings)

                PnLView()
                    .tabItem { Label(Tab.pnl.title, systemImage: Tab.pnl.systemImage) }
                    .tag(Tab.pnl)

                NewsPlaceholder()
                    .tabItem { Label(Tab.news.title, systemImage: Tab.news.systemImage) }
                    .tag(Tab.news)

                NavigationView {
                    SettingsView()
                        .environmentObject(taxProfileManager)
                        .environmentObject(remoteTaxRatesService)
                }
                .navigationViewStyle(.stack)
                .tabItem { Label(Tab.settings.title, systemImage: Tab.settings.systemImage) }
                .tag(Tab.settings)
            }
            .tint(.appBlue)

            // Offline banner
            if !networkMonitor.isConnected {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
        .sheet(isPresented: $showTaxOnboarding) {
            OnboardingView()
                .environmentObject(taxProfileManager)
        }
        .onAppear {
            // Prompt first-time tax profile setup
            if !taxProfileManager.isProfileComplete {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showTaxOnboarding = true
                }
            }
        }
    }
}

// MARK: - Offline Banner

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
            Text("Offline — showing cached prices")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.appGold.opacity(0.9))
        .clipShape(Capsule())
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}

// MARK: - Placeholder Views (replaced in later phases)



struct NewsPlaceholder: View {
    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "newspaper")
                    .font(.system(size: 40))
                    .foregroundColor(.textMuted)
                Text("News & Earnings")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.textSub)
                Text("Coming in Phase 13")
                    .font(.system(size: 12))
                    .foregroundColor(.textMuted)
            }
        }
    }
}


#Preview {
    ContentView()
        .environmentObject(NetworkMonitor())
        .environmentObject(AppLockManager())
        .environmentObject(PriceService())
        .environmentObject(TaxProfileManager.shared)
        .environmentObject(RemoteTaxRatesService.shared)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
