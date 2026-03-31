import CoreData

final class PersistenceController {

    static let shared = PersistenceController()

    // MARK: - Container
    // NSPersistentCloudKitContainer when iCloud is available, plain NSPersistentContainer otherwise.
    // Using the base type so both can be assigned without casting.

    let container: NSPersistentContainer

    // MARK: - iCloud Status

    private(set) var isCloudKitAvailable: Bool

    // MARK: - CloudKit config

    // Set to true once the CloudKit container is provisioned in the Apple Developer portal
    // and iCloud + CloudKit capability is added in Xcode Signing & Capabilities.
    private static let cloudKitEnabled = false
    private static let cloudKitContainerIdentifier = "iCloud.com.cchen96.PortfolioApp"

    // MARK: - Init

    init(inMemory: Bool = false) {
        let useCloudKit = !inMemory
            && Self.cloudKitEnabled
            && FileManager.default.ubiquityIdentityToken != nil

        isCloudKitAvailable = useCloudKit

        container = useCloudKit
            ? NSPersistentCloudKitContainer(name: "PortfolioApp")
            : NSPersistentContainer(name: "PortfolioApp")

        guard let description = container.persistentStoreDescriptions.first else {
            container.loadPersistentStores { _, _ in }
            return
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        }

        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

        if useCloudKit {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: Self.cloudKitContainerIdentifier
            )
            print("☁️ CloudKit sync enabled")
        } else {
            print("📦 Running with local store only")
        }

        container.loadPersistentStores { [weak self] description, error in
            if let error {
                assertionFailure("CoreData failed to load: \(error.localizedDescription)")
                print("❌ CoreData load error: \(error)")
                return
            }
            print("✅ CoreData store loaded: \(description.url?.lastPathComponent ?? "unknown")")
            DispatchQueue.main.async {
                self?.finishSetup()
            }
        }
    }

    private func finishSetup() {
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    // MARK: - Save

    func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("❌ CoreData save error: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Context

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    func performBackground(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }

    // MARK: - Preview Container (SwiftUI Previews)

    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        let holding = Holding(context: context)
        holding.symbol = "NVDA"
        holding.name = "NVIDIA Corporation"
        holding.assetType = .stock
        holding.sector = "Semiconductors"

        let lot = Lot(context: context)
        lot.holdingId = holding.id
        lot.lotNumber = 1
        lot.originalQty = 100
        lot.originalCostBasisPerShare = 875.00
        lot.splitAdjustedQty = 100
        lot.splitAdjustedCostBasisPerShare = 875.00
        lot.totalCostBasis = 87500.00
        lot.remainingQty = 100
        lot.purchaseDate = Calendar.current.date(byAdding: .day, value: -400, to: Date()) ?? Date()

        do {
            try context.save()
        } catch {
            print("Preview seed failed: \(error)")
        }

        return controller
    }()
}
