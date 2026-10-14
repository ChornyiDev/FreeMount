import SwiftUI

/// Shared verification step for existing network connection forms.
struct ConnectionTestSection: View {
    var title = "4. TEST CONNECTION"
    let verificationState: ConnectionVerificationState
    let canTest: Bool
    let busy: Bool
    let progressMessage: String
    let onTest: () -> Void

    var body: some View {
        ConnectionFormSection(title: title) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.md) {
                    Button(action: onTest) {
                        HStack(spacing: 6) {
                            if verificationState.isTesting {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(verificationState.isTesting ? "Testing…" : "Test Connection")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                .fill(canTest && !busy && !verificationState.isTesting ? Color.dsAccent : Color.dsTextMuted.opacity(0.4))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || verificationState.isTesting || !canTest)

                    if case .untested = verificationState {
                        Text("Verify server reachability and credentials before saving.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsTextMuted)
                    }
                }

                if case .testing = verificationState {
                    HStack(spacing: DSSpacing.xs) {
                        Text(progressMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                } else if case .verified(let message) = verificationState {
                    HStack(spacing: DSSpacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.dsGreen)
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.dsGreen)
                    }
                    .padding(DSSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .fill(Color.dsGreen.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                    .strokeBorder(Color.dsGreen.opacity(0.25), lineWidth: 1)
                            )
                    )
                } else if case .failed(let failureReason) = verificationState {
                    HStack(alignment: .top, spacing: DSSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.dsRed)
                        Text(failureReason)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DSSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .fill(Color.dsRed.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                    .strokeBorder(Color.dsRed.opacity(0.25), lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

}
