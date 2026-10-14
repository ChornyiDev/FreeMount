import SwiftUI

/// Shared fixed footer for all provider connection forms.
struct ConnectionFormFooter: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    let onCancel: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("Credentials are stored only in your macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(Color.dsTextMuted)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize()

            Button(action: onAction) {
                HStack(spacing: 5) {
                    if busy {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(enabled ? Color.dsGreen : Color.dsTextMuted.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
    }
}

