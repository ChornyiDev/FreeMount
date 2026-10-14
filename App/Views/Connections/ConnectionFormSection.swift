import SwiftUI

/// Consistent section layout for provider-specific OAuth configuration.
struct ConnectionFormSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.dsTextMuted)
            VStack(alignment: .leading, spacing: DSSpacing.sm) { content }
                .padding(DSSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous).strokeBorder(Color.dsBorderSubtle, lineWidth: 1)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
