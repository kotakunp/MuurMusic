import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cross-platform image type (UIImage on iOS, NSImage on macOS).
#if canImport(UIKit)
typealias UXImage = UIImage
#elseif canImport(AppKit)
typealias UXImage = NSImage
#endif

extension UXImage {
    /// Decodes image data on either platform.
    static func from(data: Data) -> UXImage? {
        UXImage(data: data)
    }
}

extension Image {
    /// SwiftUI image from a platform image.
    init(uxImage: UXImage) {
        #if canImport(UIKit)
        self.init(uiImage: uxImage)
        #elseif canImport(AppKit)
        self.init(nsImage: uxImage)
        #endif
    }

    /// SwiftUI image from a CoreGraphics image.
    init(uxCGImage image: CGImage) {
        #if canImport(UIKit)
        self.init(uiImage: UIImage(cgImage: image))
        #elseif canImport(AppKit)
        self.init(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        #endif
    }
}

extension Color {
    /// Creates a color from "#RRGGBB" or "#RRGGBBAA".
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let red, green, blue, alpha: Double
        switch text.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        default:
            red = 1; green = 1; blue = 1; alpha = 1
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

extension View {
    /// Hides the pointer-finger cursor differences; on macOS gives a pointing hand for tappable rows.
    @ViewBuilder
    func muurPointer() -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
/// macOS has no `EditMode`; lists there select and reorder without it. This stand-in keeps the
/// "Select / Done" state in shared views.
enum EditMode: Equatable {
    case inactive, active

    var isEditing: Bool { self == .active }
}
#endif

extension View {
    /// Applies the edit mode to lists on iOS; a no-op on macOS.
    @ViewBuilder
    func muurEditMode(_ mode: Binding<EditMode>) -> some View {
        #if os(iOS)
        environment(\.editMode, mode)
        #else
        self
        #endif
    }
}

/// The current platform trait helper.
enum PlatformInfo {
    static var isIOS: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "Apple"
        #endif
    }

    static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
}
