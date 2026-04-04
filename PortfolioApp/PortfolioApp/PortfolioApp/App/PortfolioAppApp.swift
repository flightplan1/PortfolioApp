import SwiftUI
import CoreData
import BackgroundTasks

private let bgTaskIdentifier = "com.portfolioapp.newsrefresh"

@main
struct PortfolioAppApp: App {

    let persistenceController = PersistenceController.shared

    init() {
        // BGTask handler must be registered before the app finishes launching.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            PortfolioAppApp.handleBackgroundRefresh(refreshTask)
        }
    }

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
                scheduleBackgroundRefresh()
            case .active:
                appLockManager.handleForeground()
                Task { await remoteTaxRatesService.fetchIfNeeded() }
                let ctx = persistenceController.container.viewContext
                PriceAlertService.shared.start(priceService: priceService, context: ctx)
                TreasuryMaturityService.shared.start(context: ctx)
                let prefs = NotificationPreferencesManager.shared
                Task {
                    let holdings = (try? ctx.fetch(Holding.allActiveRequest())) ?? []
                    await SplitService.shared.detectSplitsIfNeeded(holdings: holdings, context: ctx)

                    // Earnings notifications — weekly re-check
                    let stockSymbols = holdings
                        .filter { $0.assetType == .stock || $0.assetType == .etf }
                        .map { $0.symbol }

                    // Sync dynamic industry graph for any new/removed stock holdings
                    await DynamicGraphService.shared.syncWithHoldings(symbols: stockSymbols)
                    await EarningsService.shared.fetchIfNeeded(symbols: stockSymbols)
                    await EarningsNotificationManager.shared.scheduleIfNeeded(
                        events: EarningsService.shared.events, prefs: prefs
                    )

                    // LT threshold notifications — every foreground
                    let lotReq = NSFetchRequest<Lot>(entityName: "Lot")
                    lotReq.predicate = NSPredicate(format: "isClosed == NO AND isSoftDeleted == NO")
                    let lots = (try? ctx.fetch(lotReq)) ?? []
                    await LTThresholdNotificationManager.shared.scheduleAll(
                        lots: lots, holdings: holdings, prefs: prefs
                    )
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Background Refresh

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)  // no sooner than 30 min
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        let ctx = PersistenceController.shared.container.viewContext
        let taskOp = Task { @MainActor in
            let holdings = (try? ctx.fetch(Holding.allActiveRequest())) ?? []
            let stockSymbols = holdings
                .filter { $0.assetType == .stock || $0.assetType == .etf }
                .map { $0.symbol }

            let prefs = NotificationPreferencesManager.shared
            await NewsService.shared.fetch(symbols: stockSymbols)
            await NewsService.shared.notifyNewArticles(prefs: prefs)

            await EarningsService.shared.fetch(symbols: stockSymbols)
            await EarningsNotificationManager.shared.scheduleAll(
                events: EarningsService.shared.events, prefs: prefs
            )
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            taskOp.cancel()
            task.setTaskCompleted(success: false)
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
