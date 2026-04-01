import Foundation
import CoreData

// MARK: - SplitSnapshot
// Local-only (syncable = NO) pre-split lot state snapshot.
// Allows reverting a split within 24 hours of application.
// snapshotData is a JSON-encoded [LotSnapshot].

@objc(SplitSnapshot)
public class SplitSnapshot: NSManagedObject, Identifiable {

    @NSManaged public var id: UUID
    @NSManaged public var splitEventId: UUID
    @NSManaged public var snapshotData: Data?
    @NSManaged public var createdAt: Date
    @NSManaged public var revertableUntil: Date

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date()
        revertableUntil = Date().addingTimeInterval(24 * 60 * 60)
    }
}

// MARK: - Lot Snapshot (Codable)

/// Serialized state of a single Lot before a split was applied.
struct LotSnapshot: Codable {
    let lotId: UUID
    let splitAdjustedQty: Decimal
    let splitAdjustedCostBasisPerShare: Decimal
    let remainingQty: Decimal
    let splitHistoryData: Data?
}

// MARK: - Computed

extension SplitSnapshot {
    var isStillRevertable: Bool { Date() < revertableUntil }

    var lotSnapshots: [LotSnapshot] {
        get {
            guard let data = snapshotData else { return [] }
            return (try? JSONDecoder().decode([LotSnapshot].self, from: data)) ?? []
        }
        set {
            snapshotData = try? JSONEncoder().encode(newValue)
        }
    }
}

// MARK: - Factory

extension SplitSnapshot {
    static func create(
        in context: NSManagedObjectContext,
        splitEventId: UUID,
        lots: [Lot]
    ) -> SplitSnapshot {
        let snapshot = SplitSnapshot(context: context)
        snapshot.splitEventId = splitEventId
        snapshot.lotSnapshots = lots.map {
            LotSnapshot(
                lotId: $0.id,
                splitAdjustedQty: $0.splitAdjustedQty,
                splitAdjustedCostBasisPerShare: $0.splitAdjustedCostBasisPerShare,
                remainingQty: $0.remainingQty,
                splitHistoryData: $0.splitHistoryData
            )
        }
        return snapshot
    }
}

// MARK: - Fetch Requests

extension SplitSnapshot {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<SplitSnapshot> {
        NSFetchRequest<SplitSnapshot>(entityName: "SplitSnapshot")
    }

    static func forSplitEvent(_ splitEventId: UUID) -> NSFetchRequest<SplitSnapshot> {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "splitEventId == %@", splitEventId as CVarArg)
        request.fetchLimit = 1
        return request
    }
}
