import SwiftUI

struct LockScreen: View {
    @EnvironmentObject private var appLockManager: AppLockManager

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if appLockManager.showPINSetup {
                PINSetupView()
                    .environmentObject(appLockManager)
            } else if appLockManager.showPINEntry {
                PINEntryView()
                    .environmentObject(appLockManager)
            } else {
                biometricView
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appLockManager.authenticate()
            }
        }
    }

    // MARK: - Biometric View

    private var biometricView: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundColor(.appBlue)

                Text("PortfolioApp")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.textPrimary)
            }

            Spacer()

            VStack(spacing: 16) {
                Button(action: { appLockManager.authenticate() }) {
                    HStack(spacing: 10) {
                        Image(systemName: appLockManager.biometricType.systemImageName)
                            .font(.system(size: 20))
                        Text("Unlock with \(appLockManager.biometricType.displayName)")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.appBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(appLockManager.isAuthenticating)
                .opacity(appLockManager.isAuthenticating ? 0.6 : 1)
                .padding(.horizontal, 32)

                if appLockManager.isAuthenticating {
                    ProgressView().tint(.textSub)
                }

                Button("Use PIN Instead") {
                    appLockManager.showPINFallback()
                }
                .font(.system(size: 14))
                .foregroundColor(.textSub)
            }
            .padding(.bottom, 60)
        }
    }
}

// MARK: - PIN Entry View

struct PINEntryView: View {
    @EnvironmentObject private var appLockManager: AppLockManager
    @State private var pin: String = ""
    private let pinLength = 6

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.appBlue)
                Text("Enter PIN")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.textPrimary)
                if let err = appLockManager.pinError {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundColor(.appRed)
                }
            }

            // Dot indicators
            HStack(spacing: 16) {
                ForEach(0..<pinLength, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.appBlue : Color.appBorder)
                        .frame(width: 14, height: 14)
                        .animation(.easeInOut(duration: 0.1), value: pin.count)
                }
            }

            Spacer()

            // Numpad
            numpad

            Button("Use Face ID / Touch ID") {
                pin = ""
                appLockManager.authenticate()
            }
            .font(.system(size: 14))
            .foregroundColor(.textSub)
            .padding(.bottom, 40)
        }
    }

    private var numpad: some View {
        VStack(spacing: 12) {
            ForEach([[1,2,3],[4,5,6],[7,8,9]], id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { digit in
                        numpadButton(label: "\(digit)") { append("\(digit)") }
                    }
                }
            }
            HStack(spacing: 20) {
                // Empty spacer slot
                Circle().fill(Color.clear).frame(width: 72, height: 72)
                numpadButton(label: "0") { append("0") }
                numpadButton(systemImage: "delete.left") { deleteLast() }
            }
        }
        .padding(.horizontal, 40)
    }

    private func numpadButton(label: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.surface)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                if let label {
                    Text(label)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundColor(.textPrimary)
                } else if let img = systemImage {
                    Image(systemName: img)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func append(_ digit: String) {
        guard pin.count < pinLength else { return }
        pin += digit
        if pin.count == pinLength {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appLockManager.verifyPIN(pin)
                if appLockManager.pinError != nil { pin = "" }
            }
        }
    }

    private func deleteLast() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }
}

// MARK: - PIN Setup View

struct PINSetupView: View {
    @EnvironmentObject private var appLockManager: AppLockManager
    @State private var pin: String = ""
    @State private var confirmPin: String = ""
    @State private var isConfirming: Bool = false
    @State private var mismatchError: Bool = false
    private let pinLength = 6

    var currentPin: String { isConfirming ? confirmPin : pin }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.appBlue)
                Text(isConfirming ? "Confirm PIN" : "Set Up PIN")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text(isConfirming ? "Enter your PIN again to confirm" : "Choose a 6-digit PIN as a fallback to Face ID / Touch ID")
                    .font(.system(size: 13))
                    .foregroundColor(.textSub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if mismatchError {
                    Text("PINs didn't match. Try again.")
                        .font(.system(size: 13))
                        .foregroundColor(.appRed)
                }
            }

            // Dot indicators
            HStack(spacing: 16) {
                ForEach(0..<pinLength, id: \.self) { i in
                    Circle()
                        .fill(i < currentPin.count ? Color.appBlue : Color.appBorder)
                        .frame(width: 14, height: 14)
                        .animation(.easeInOut(duration: 0.1), value: currentPin.count)
                }
            }

            Spacer()

            numpad

            Spacer().frame(height: 40)
        }
    }

    private var numpad: some View {
        VStack(spacing: 12) {
            ForEach([[1,2,3],[4,5,6],[7,8,9]], id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(row, id: \.self) { digit in
                        numpadButton(label: "\(digit)") { append("\(digit)") }
                    }
                }
            }
            HStack(spacing: 20) {
                Circle().fill(Color.clear).frame(width: 72, height: 72)
                numpadButton(label: "0") { append("0") }
                numpadButton(systemImage: "delete.left") { deleteLast() }
            }
        }
        .padding(.horizontal, 40)
    }

    private func numpadButton(label: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.surface)
                    .frame(width: 72, height: 72)
                    .overlay(Circle().stroke(Color.appBorder, lineWidth: 1))
                if let label {
                    Text(label)
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundColor(.textPrimary)
                } else if let img = systemImage {
                    Image(systemName: img)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func append(_ digit: String) {
        mismatchError = false
        if isConfirming {
            guard confirmPin.count < pinLength else { return }
            confirmPin += digit
            if confirmPin.count == pinLength {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { submit() }
            }
        } else {
            guard pin.count < pinLength else { return }
            pin += digit
            if pin.count == pinLength {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isConfirming = true
                }
            }
        }
    }

    private func deleteLast() {
        mismatchError = false
        if isConfirming {
            if !confirmPin.isEmpty { confirmPin.removeLast() }
        } else {
            if !pin.isEmpty { pin.removeLast() }
        }
    }

    private func submit() {
        if pin == confirmPin {
            appLockManager.savePIN(pin)
        } else {
            mismatchError = true
            confirmPin = ""
            isConfirming = false
        }
    }
}

#Preview {
    LockScreen()
        .environmentObject(AppLockManager())
}
