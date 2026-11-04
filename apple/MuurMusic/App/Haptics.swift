import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cat-themed haptics. The "purr" is a short double-tap feedback played when favoriting.
enum MuurHaptics {
    /// A gentle double thump — the purr.
    @MainActor
    static func purr(enabled: Bool = true) {
        guard enabled else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            generator.impactOccurred(intensity: 0.6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            generator.impactOccurred(intensity: 0.35)
        }
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        #endif
    }

    /// Light confirmation tap (queue changes, downloads).
    @MainActor
    static func tap(enabled: Bool = true) {
        guard enabled else { return }
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        #endif
    }
}
