import SwiftUI

/// Shared signed-out and authorized presentation for Google connections.
struct ConnectionAuthorizationStateView: View {
    let isAuthorized: Bool
    let busy: Bool
    var authorizedTitle = "Google Account Authorized"
    var detail = "Ready to configure this connection"
    var actionTitle = "Switch"
    var prompt = "Sign in with Google to configure this connection."
    var signInTitle = "Sign in with Google"
    let onAuthorize: () -> Void

    var body: some View {
        if isAuthorized {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.dsGreen)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(authorizedTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dsGreen)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dsTextMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onAuthorize) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dsAccent)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.dsAccent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            .padding(DSSpacing.sm)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                .fill(Color.dsGreen.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .strokeBorder(Color.dsGreen.opacity(0.25), lineWidth: 1)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(signInTitle, action: onAuthorize)
                .buttonStyle(.bordered)
                .disabled(busy)
        }
    }
}
