import SwiftUI

// MARK: - Design System Color Tokens
// Source: UI_REFERENCE.md

extension Color {

    // MARK: - Backgrounds
    static let appBg          = Color(hex: "#111827") // App background
    static let surface         = Color(hex: "#1A2235") // Card background
    static let surfaceAlt      = Color(hex: "#1E2840") // Nested card / stat tile
    static let surfaceDeep     = Color(hex: "#0D1520") // Deepest nesting (sell sheet)

    // MARK: - Borders
    static let appBorder       = Color(hex: "#1A2535")
    static let borderLight     = Color(hex: "#1E2D42")

    // MARK: - Text
    static let textPrimary     = Color(hex: "#E8EFF8")
    static let textSub         = Color(hex: "#8A9DC0")
    static let textMuted       = Color(hex: "#6B7FA0")

    // MARK: - Semantic Colors
    static let appGreen        = Color(hex: "#00D4A8")
    static let appGreenDim     = Color(hex: "#00D4A8").opacity(0.08)
    static let appGreenBorder  = Color(hex: "#00D4A8").opacity(0.19)

    static let appRed          = Color(hex: "#FF4D6A")
    static let appRedDim       = Color(hex: "#FF4D6A").opacity(0.08)
    static let appRedBorder    = Color(hex: "#FF4D6A").opacity(0.19)

    static let appBlue         = Color(hex: "#3B8EF0")
    static let appBlueDim      = Color(hex: "#3B8EF0").opacity(0.08)
    static let appBlueBorder   = Color(hex: "#3B8EF0").opacity(0.19)

    static let appGold         = Color(hex: "#F5A623")
    static let appGoldDim      = Color(hex: "#F5A623").opacity(0.08)
    static let appGoldBorder   = Color(hex: "#F5A623").opacity(0.19)

    static let appPurple       = Color(hex: "#A855F7")
    static let appPurpleDim    = Color(hex: "#A855F7").opacity(0.08)

    static let appTeal         = Color(hex: "#06B6D4")
    static let appTealDim      = Color(hex: "#06B6D4").opacity(0.11)

    // MARK: - Asset Type Chip Colors
    static let chipStock       = Color.appBlue
    static let chipETF         = Color.appTeal
    static let chipCrypto      = Color.appGold
    static let chipOption      = Color.appPurple
    static let chipCash        = Color.appGreen
    static let chipTreasury    = Color(hex: "#94A3B8")

    // MARK: - Status
    static func pnlColor(_ value: Decimal) -> Color {
        value >= 0 ? .appGreen : .appRed
    }

    static func pnlColor(_ value: Double) -> Color {
        value >= 0 ? .appGreen : .appRed
    }
}

// MARK: - Hex Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Typography

struct AppFont {
    // Syne — Display / Headers
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("Syne-Bold", size: size).weight(weight)
    }

    // JetBrains Mono — Numbers / Monospace
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrainsMono-Regular", size: size).weight(weight)
    }

    // Mulish — Body / Labels
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Mulish-Regular", size: size).weight(weight)
    }

    // Stat tile label: 9pt mono uppercase
    static var statLabel: Font { mono(9, weight: .medium) }
    // Stat tile value: 13pt mono bold
    static var statValue: Font { mono(13, weight: .bold) }
    // Section title: 10pt mono uppercase
    static var sectionTitle: Font { mono(10, weight: .regular) }
}

// MARK: - View Modifiers

extension View {
    func cardStyle() -> some View {
        self
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
    }

    func statTileStyle() -> some View {
        self
            .background(Color.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func sectionTitleStyle() -> some View {
        self
            .font(AppFont.sectionTitle)
            .foregroundColor(.textMuted)
            .textCase(.uppercase)
            .kerning(1.0)
    }
}
