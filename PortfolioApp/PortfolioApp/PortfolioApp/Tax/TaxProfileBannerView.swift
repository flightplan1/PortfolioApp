import SwiftUI

/// Non-dismissible banner shown whenever the tax profile is incomplete.
/// Displayed at the top of P&L, Dashboard, PositionDetail, and SellLot screens.
struct TaxProfileBannerView: View {

    @EnvironmentObject private var taxProfileManager: TaxProfileManager
    @State private var showOnboarding = false

    var body: some View {
        if !taxProfileManager.isProfileComplete {
            bannerContent
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                        .environmentObject(taxProfileManager)
                }
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.appGold)

            VStack(alignment: .leading, spacing: 3) {
                Text("Tax profile incomplete")
                    .font(AppFont.body(13, weight: .semibold))
                    .foregroundColor(.textPrimary)
                Text("Estimates shown use Single filer, $70k income defaults and may be significantly inaccurate.")
                    .font(AppFont.body(11))
                    .foregroundColor(.textSub)
            }

            Spacer()

            Button {
                showOnboarding = true
            } label: {
                Text("Set up →")
                    .font(AppFont.body(12, weight: .semibold))
                    .foregroundColor(.appBlue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appGold.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appGold.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
