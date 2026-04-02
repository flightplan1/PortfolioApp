import SwiftUI
import CoreData

@main
struct PortfolioAppApp: App {

    let persistenceController = PersistenceController.shared

    @StateObject private var networkMonitor         = NetworkMonitor()
    @StateObject private var appLockManager         = AppLockManager()
    @StateObject private var priceService           = PriceService()
    @StateObject private var taxProfileManager      = TaxProfileManager.shared
    @StateObject private var remoteTaxRatesService  = RemoteTaxRatesService.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(networkMonitor)
                .environmentObject(appLockManager)
                .environmentObject(priceService)
                .environmentObject(taxProfileManager)
                .environmentObject(remoteTaxRatesService)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                persistenceController.save()
                appLockManager.handleBackground()
            case .active:
                appLockManager.handleForeground()
                Task { await remoteTaxRatesService.fetchIfNeeded() }
                let ctx = persistenceController.container.viewContext
                PriceAlertService.shared.start(priceService: priceService, context: ctx)
                TreasuryMaturityService.shared.start(context: ctx)
                Task {
                    let holdings = (try? ctx.fetch(Holding.allActiveRequest())) ?? []
                    await SplitService.shared.detectSplitsIfNeeded(holdings: holdings, context: ctx)
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject private var appLockManager: AppLockManager
    @ObservedObject private var splitService = SplitService.shared
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        ZStack {
            if appLockManager.lockEnabled && !appLockManager.isUnlocked {
                LockScreen()
            } else {
                ContentView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLockManager.isUnlocked)
        .sheet(item: Binding(
            get: { splitService.pendingSplits.first },
            set: { _ in }
        )) { pending in
            SplitConfirmationView(
                pending: pending,
                onApply: {},
                onSkip: {}
            )
            .environment(\.managedObjectContext, context)
        }
    }
}
