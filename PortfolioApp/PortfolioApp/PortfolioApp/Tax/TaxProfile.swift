import Foundation
import Combine

// MARK: - Filing Status

enum FilingStatus: String, CaseIterable, Identifiable, Codable {
    case single = "single"
    case mfj    = "mfj"
    case mfs    = "mfs"
    case hoh    = "hoh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single"
        case .mfj:    return "Married Filing Jointly"
        case .mfs:    return "Married Filing Separately"
        case .hoh:    return "Head of Household"
        }
    }

    var shortName: String {
        switch self {
        case .single: return "Single"
        case .mfj:    return "MFJ"
        case .mfs:    return "MFS"
        case .hoh:    return "HOH"
        }
    }
}

// MARK: - Tax Profile

struct TaxProfile: Codable, Equatable {
    var filingStatus: FilingStatus
    var ordinaryIncome: Decimal
    var state: String?       // 2-letter code e.g. "NY"
    var city: String?        // city key e.g. "NYC"
    var isResident: Bool     // for city resident/non-resident rates

    /// Profile is complete when filing status, income, and state are all set.
    var isComplete: Bool { state != nil }

    static let `default` = TaxProfile(
        filingStatus: .single,
        ordinaryIncome: 70_000,
        state: nil,
        city: nil,
        isResident: true
    )

    /// Short label for disclaimer footers: e.g. "Single · $70k income"
    var shortLabel: String {
        let incomeInt = NSDecimalNumber(decimal: ordinaryIncome).intValue
        let incomeStr = incomeInt >= 1_000
            ? "$\(incomeInt / 1_000)k income"
            : "$\(incomeInt) income"
        return "\(filingStatus.shortName) · \(incomeStr)"
    }
}

// MARK: - TaxProfileManager

@MainActor
final class TaxProfileManager: ObservableObject {

    static let shared = TaxProfileManager()

    private let kvStore    = NSUbiquitousKeyValueStore.default
    private let defaults   = UserDefaults.standard
    private let profileKey = "com.portfolioapp.taxProfile.v1"

    @Published var profile: TaxProfile = .default
    @Published var isProfileComplete: Bool = false

    private init() {
        load()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.load() }
        }
        kvStore.synchronize()
    }

    func save(_ newProfile: TaxProfile) {
        profile = newProfile
        isProfileComplete = newProfile.isComplete
        guard let data = try? JSONEncoder().encode(newProfile) else { return }
        // Dual-save: iCloud KV for cross-device sync, UserDefaults as local fallback
        // (NSUbiquitousKeyValueStore is silently unavailable when iCloud isn't signed in)
        kvStore.set(data, forKey: profileKey)
        kvStore.synchronize()
        defaults.set(data, forKey: profileKey)
    }

    private func load() {
        // Prefer iCloud KV store; fall back to UserDefaults (e.g. Simulator without iCloud)
        let data = kvStore.data(forKey: profileKey) ?? defaults.data(forKey: profileKey)
        if let data, let p = try? JSONDecoder().decode(TaxProfile.self, from: data) {
            profile = p
            isProfileComplete = p.isComplete
        } else {
            profile = .default
            isProfileComplete = false
        }
    }
}
