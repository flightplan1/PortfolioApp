import SwiftUI

struct LockScreen: View {
    @EnvironmentObject private var appLockManager: AppLockManager

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Logo / App Icon
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

                // Unlock button
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
                        ProgressView()
                            .tint(.textSub)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            // Trigger biometric prompt automatically on lock screen appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appLockManager.authenticate()
            }
        }
    }
}

#Preview {
    LockScreen()
        .environmentObject(AppLockManager())
}
