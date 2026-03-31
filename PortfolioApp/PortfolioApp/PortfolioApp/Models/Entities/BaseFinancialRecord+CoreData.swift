import Foundation
import CoreData

// MARK: - BaseFinancialRecord
// Abstract parent entity for all financial records.
// Provides CloudKit conflict tracking fields.
// In the CoreData model editor: set this entity as Abstract = true.
// All financial entities (Holding, Lot, Transaction) set their Parent Entity to BaseFinancialRecord.

@objc(BaseFinancialRecord)
public class BaseFinancialRecord: NSManagedObject {

    // MARK: - CloudKit Conflict Tracking

    /// CloudKit record ID — populated by NSPersistentCloudKitContainer
    @NSManaged public var ckRecordID: String?

    /// CloudKit change tag — used to detect concurrent edits
    @NSManaged public var ckRecordChangeTag: String?

    /// Human-readable device name at time of last modification
    /// Shown in the conflict resolution UI so the user knows which device made the change.
    @NSManaged public var lastModifiedDevice: String?

    /// Timestamp of last modification — used for non-financial conflict resolution (last-write-wins)
    @NSManaged public var lastModifiedAt: Date?

    // MARK: - Conflict Resolution

    /// Financial records (Lot, Transaction) must ALWAYS be surfaced to the user.
    /// Non-financial records use last-write-wins by timestamp.
    func resolveConflict(against remote: BaseFinancialRecord) -> ConflictResolution {
        if self is Lot || self is Transaction {
            return .requireUserResolution(local: self, remote: remote)
        }
        let localDate = lastModifiedAt ?? .distantPast
        let remoteDate = remote.lastModifiedAt ?? .distantPast
        return localDate > remoteDate ? .keepLocal : .keepRemote
    }

    // MARK: - Last Modified Tracking

    func markModified() {
        lastModifiedAt = Date()
        lastModifiedDevice = UIDevice.current.name
    }
}

// MARK: - Conflict Resolution Types

enum ConflictResolution {
    case keepLocal
    case keepRemote
    case requireUserResolution(local: BaseFinancialRecord, remote: BaseFinancialRecord)
}

// MARK: - UIDevice import shim (avoids importing UIKit everywhere)
import UIKit
