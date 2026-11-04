import SwiftUI

/// Brand tokens from docs/specs/SHARED_FORMATS.md ("midnight cat" theme).
enum MuurTheme {
    // MARK: Corner radii
    static let radiusRow: CGFloat = 8
    static let radiusCard: CGFloat = 14
    static let radiusArtwork: CGFloat = 22

    // MARK: Dark palette
    static let bgDark = Color(hex: "#17122B")
    static let bgElevatedDark = Color(hex: "#211A3D")
    static let bgHighlightDark = Color(hex: "#2C2350")

    // MARK: Light palette
    static let bgLight = Color(hex: "#F7F5FC")
    static let bgElevatedLight = Color(hex: "#FFFFFF")
    static let bgHighlightLight = Color(hex: "#ECE7FA")

    // MARK: Accents (same in both schemes)
    static let accentAmber = Color(hex: "#FFB23F")
    static let accentViolet = Color(hex: "#8B6CFF")
    static let danger = Color(hex: "#FF6B6B")
    static let success = Color(hex: "#5EE0A0")

    // MARK: Text
    static let textPrimaryDark = Color(hex: "#F5F2FF")
    static let textSecondaryDark = Color(hex: "#A79FC7")
    static let textPrimaryLight = Color(hex: "#1B1630")
    static let textSecondaryLight = Color(hex: "#5E5780")
}

/// Resolved palette for one color scheme.
struct MuurPalette {
    let bg: Color
    let bgElevated: Color
    let bgHighlight: Color
    let textPrimary: Color
    let textSecondary: Color

    init(scheme: ColorScheme) {
        switch scheme {
        case .light:
            bg = MuurTheme.bgLight
            bgElevated = MuurTheme.bgElevatedLight
            bgHighlight = MuurTheme.bgHighlightLight
            textPrimary = MuurTheme.textPrimaryLight
            textSecondary = MuurTheme.textSecondaryLight
        default:
            bg = MuurTheme.bgDark
            bgElevated = MuurTheme.bgElevatedDark
            bgHighlight = MuurTheme.bgHighlightDark
            textPrimary = MuurTheme.textPrimaryDark
            textSecondary = MuurTheme.textSecondaryDark
        }
    }
}

extension ColorScheme {
    /// The MuurMusic palette for this scheme.
    var muur: MuurPalette { MuurPalette(scheme: self) }
}

extension View {
    /// Card background: elevated brand color with the card corner radius.
    func muurCard(_ palette: MuurPalette, radius: CGFloat = MuurTheme.radiusCard) -> some View {
        background(palette.bgElevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
