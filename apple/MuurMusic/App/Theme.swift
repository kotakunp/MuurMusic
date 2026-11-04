import SwiftUI
import MuurCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Brand tokens. Screens use system backgrounds and materials so Liquid Glass and Dark Mode
/// render the way the OS intends; the brand shows up through the accent and artwork.
enum MuurTheme {
    // MARK: Corner radii
    static let radiusRow: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let radiusArtwork: CGFloat = 14

    // MARK: Brand colors
    static let accentAmber = Color(hex: "#FFB23F")
    static let accentViolet = Color(hex: "#8B6CFF")
    static let danger = Color.red
    static let success = Color.green
}

extension AccentChoice {
    /// The accent as an adaptive color. The brand hexes are bright enough for dark backgrounds
    /// but fail contrast on white, so light mode uses a deeper shade of the same hue.
    var color: Color {
        Color(light: lightHex, dark: hex)
    }

    private var lightHex: String {
        switch self {
        case .amber: return "#B86A00"
        case .violet: return "#6A4BE3"
        case .mint: return "#0B8F72"
        case .rose: return "#D63A73"
        case .sky: return "#1673C6"
        }
    }
}

extension MuurSettings {
    var accentColor: Color { accent.color }
}

extension Color {
    /// A color that resolves differently in light and dark appearance.
    init(light: String, dark: String) {
        #if canImport(UIKit)
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #elseif canImport(AppKit)
        let lightColor = NSColor(Color(hex: light))
        let darkColor = NSColor(Color(hex: dark))
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #endif
    }

    /// The platform's base window/page background.
    static var muurBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

extension View {
    /// Liquid Glass on iOS 26 / macOS 26, a regular material before that.
    @ViewBuilder
    func muurGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

/// Wide capsule button used for Play / Shuffle in collection headers.
struct MuurPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(.fill.tertiary, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
