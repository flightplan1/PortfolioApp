import SwiftUI

/// Persistent gold banner shown when the active tax rates are from a prior year.
/// Shown at the top of any screen that uses tax estimates.
struct OutdatedRatesBannerView: View {

    @EnvironmentObject private var remoteTaxRatesService: RemoteTaxRatesService

    var body: some View {
        if remoteTaxRatesService.isOutdated {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.appGold)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TAX RATES MAY BE OUTDATED")
                        .font(AppFont.mono(10, weight: .bold))
                        .foregroundColor(.appGold)
                        .kerning(0.5)
                    Text("Using \(remoteTaxRatesService.ratesSource.label). Update in Settings → Tax Rates.")
                        .font(AppFont.body(12))
                        .foregroundColor(.appGold.opacity(0.85))
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.appGoldDim)
            .overlay(
                Rectangle()
                    .frame(width: 3)
                    .foregroundColor(.appGold),
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
