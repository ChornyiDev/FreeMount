import SwiftUI
import AppKit

// MARK: - Color Tokens

/// Builds an appearance-adaptive `Color` from light/dark 24-bit hex literals.
/// Resolves automatically against the effective appearance of the view hierarchy.
func dsAdaptive(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
    })
}

extension NSColor {
    /// Initialises an sRGB `NSColor` from a 24-bit hex literal (e.g. `0x0a84ff`).
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >>  8) & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha:   1
        )
    }
}

extension Color {
    /// `#0a84ff` — Apple Blue accent
    static let dsAccent = Color(hex: 0x0a84ff)
    /// Primary label — adapts to the system appearance.
    static let dsTextPrimary = Color.primary
    /// Secondary label — adapts to the system appearance.
    static let dsTextSecondary = Color.secondary
    /// Muted / placeholder label — adapts to the system appearance.
    static let dsTextMuted = Color(nsColor: .tertiaryLabelColor)
    /// Subtle separator stroke — adapts to the system appearance.
    static let dsBorderSubtle = Color.primary.opacity(0.10)
    /// Medium separator stroke — adapts to the system appearance.
    static let dsBorderMedium = Color.primary.opacity(0.20)

    // Status colours (darker in light mode for contrast, brighter in dark mode)
    static let dsGreen = dsAdaptive(light: 0x0f9d6b, dark: 0x34d399)  // active / success
    static let dsAmber = dsAdaptive(light: 0xb45309, dark: 0xfbbf24)  // transitioning / warning
    static let dsRed   = dsAdaptive(light: 0xdc2626, dark: 0xf87171)  // error
    static let dsCyan  = dsAdaptive(light: 0x0284c7, dark: 0x38bdf8)  // throughput / info

    /// Initialises a `Color` from a 24-bit hex literal (e.g. `0x0a84ff`).
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255
        )
    }
}

// MARK: - Spacing & Radius Tokens

enum DSSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum DSRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 18
}

// MARK: - Animation Tokens

enum DSAnimation {
    /// Snappy response for selections and toggles
    static let snap    = Animation.spring(response: 0.25, dampingFraction: 0.72)
    /// Gentle entrance for banners and detail panels
    static let gentle  = Animation.spring(response: 0.40, dampingFraction: 0.70)
    /// Subtle cross-dissolve for tab switches
    static let dissolve = Animation.easeInOut(duration: 0.20)
}

// MARK: - Glass Card ViewModifier

/// Applies the frosted-glass card look from `prototypes/stitch/`.
struct DSGlassCard: ViewModifier {
    var cornerRadius: CGFloat = DSRadius.md

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.015)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.dsBorderSubtle, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func dsGlassCard(cornerRadius: CGFloat = DSRadius.md) -> some View {
        self.modifier(DSGlassCard(cornerRadius: cornerRadius))
    }
}

// MARK: - Status Chip ViewModifier

/// Compact status pill (e.g. "Active", "Offline").
struct DSStatusChip: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
            .overlay(
                Capsule().strokeBorder(color.opacity(0.30), lineWidth: 1)
            )
    }
}

// MARK: - Pulse Dot

/// Animated pulsing status dot matching the `prototypes/stitch/menubar.html` design.
struct DSPulseDot: View {
    let color: Color
    var animate: Bool = true
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.7

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(opacity * 0.4))
                .scaleEffect(scale)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard animate else { return }
            withAnimation(
                .easeInOut(duration: 1.1)
                .repeatForever(autoreverses: true)
            ) {
                scale = 1.85
                opacity = 0.0
            }
        }
    }
}
