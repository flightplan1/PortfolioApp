import Foundation
import LocalAuthentication
import Security
import Combine

final class AppLockManager: ObservableObject {

    @Published private(set) var isUnlocked: Bool = false
    @Published private(set) var isAuthenticating: Bool = false
    @Published private(set) var showPINEntry: Bool = false
    @Published private(set) var showPINSetup: Bool = false
    @Published private(set) var pinError: String? = nil

    @Published var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: "biometricLockEnabled") }
    }
    @Published var lockAfterSeconds: Int {
        didSet { UserDefaults.standard.set(lockAfterSeconds, forKey: "lockAfterSeconds") }
    }

    private var backgroundedAt: Date?
    private let pinKeychainService = "com.portfolioapp.apppin"

    var hasPIN: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pinKeychainService,
            kSecReturnData as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

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

        // If biometrics aren't available, go straight to PIN
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            showPINFallback()
            return
        }

        isAuthenticating = true

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock your portfolio"
        ) { [weak self] success, _ in
            DispatchQueue.main.async {
                self?.isAuthenticating = false
                if success {
                    self?.isUnlocked = true
                } else {
                    self?.showPINFallback()
                }
            }
        }
    }

    func showPINFallback() {
        pinError = nil
        if hasPIN {
            showPINEntry = true
        } else {
            showPINSetup = true
        }
    }

    func verifyPIN(_ pin: String) {
        guard let stored = loadPIN() else {
            pinError = "No PIN found. Please set up a new PIN."
            showPINEntry = false
            showPINSetup = true
            return
        }
        if pin == stored {
            pinError = nil
            showPINEntry = false
            isUnlocked = true
        } else {
            pinError = "Incorrect PIN. Try again."
        }
    }

    func savePIN(_ pin: String) {
        let data = Data(pin.utf8)
        let deleteQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: pinKeychainService]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: pinKeychainService,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                                        kSecValueData as String: data]
        SecItemAdd(addQuery as CFDictionary, nil)
        showPINSetup = false
        isUnlocked = true
    }

    private func loadPIN() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: pinKeychainService,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
