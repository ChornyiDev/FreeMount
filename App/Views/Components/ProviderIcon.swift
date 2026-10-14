import SwiftUI

/// Renders provider branding consistently across the app.
///
/// A provider can supply a licensed asset through its registration. Until an
/// asset is bundled, the view uses the provider's SF Symbol fallback.
struct ProviderIcon: View {
    let providerID: ProviderID
    let size: CGFloat
    var cornerRadius: CGFloat? = nil

    private var provider: CloudProvider? {
        ProviderRegistry.shared.provider(for: providerID)
    }

    private var accentColor: Color {
        Color(hex: provider?.accentColorHex ?? 0x8E8E93)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: cornerRadius ?? size * 0.24,
                style: .continuous
            )
            .fill(accentColor.opacity(0.18))

            if let assetName = provider?.iconAssetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(accentColor)
            } else {
                Image(systemName: provider?.fallbackSystemIconName ?? "externaldrive.fill")
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider?.displayName ?? providerID.rawValue)
    }
}
