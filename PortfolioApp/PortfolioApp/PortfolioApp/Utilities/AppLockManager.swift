import Foundation
import LocalAuthentication
import Combine

final class AppLockManager: ObservableObject {

    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var isAuthenticating: Bool = false

    // Stored in UserDefaults. Will migrate to NSUbiquitousKeyValueStore in Phase 7.
    @Published var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "biometricLockEnabled") }
    }
    @Published var lockAfterSeconds: Int {
        didSet { UserDefaults.standard.set(lockAfterSeconds, forKey: "lockAfterSeconds") }
    }

    private var backgroundedAt: Date?

    init() {
        let storedEnabled = UserDefaults.standard.object(forKey: "biometricLockEnabled")
        lockEnabled = storedEnabled == nil ? true : UserDefaults.standard.bool(forKey: "biometricLockEnabled")
        lockAfterSeconds = UserDefaults.standard.integer(forKey: "lockAfterSeconds")
    }

    // MARK: - Authentication

    func authenticate() {
        guard !isAuthenticating else { return }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true
            return
        }

        isAuthenticating = true

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock your portfolio"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.isAuthenticating = false
                self?.isUnlocked = success
            }
        }
    }

    // MARK: - Scene Lifecycle

    func handleBackground() {
        backgroundedAt = Date()
    }

    func handleForeground() {
        #if DEBUG
        isUnlocked = true
        #else
        guard lockEnabled else {
            isUnlocked = true
            return
        }
        guard !isAuthenticating else { return }
        guard !isUnlocked else { return }

        if let backgroundedAt {
            let elapsed = Date().timeIntervalSince(backgroundedAt)
            if elapsed > Double(lockAfterSeconds) {
                isUnlocked = false
                authenticate()
            }
        } else {
            authenticate()
        }
        #endif
    }

    func lock() {
        isUnlocked = false
    }

    // MARK: - Biometric Availability

    var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID:   return .faceID
        case .touchID:  return .touchID
        default:        return .none
        }
    }

    enum BiometricType {
        case faceID, touchID, none

        var displayName: String {
            switch self {
            case .faceID:  return "Face ID"
            case .touchID: return "Touch ID"
            case .none:    return "Passcode"
            }
        }

        var systemImageName: String {
            switch self {
            case .faceID:  return "faceid"
            case .touchID: return "touchid"
            case .none:    return "lock.fill"
            }
        }
    }

    static let lockDelayOptions: [(label: String, seconds: Int)] = [
        ("Immediately", 0),
        ("After 30 seconds", 30),
        ("After 1 minute", 60),
        ("After 5 minutes", 300)
    ]
}
