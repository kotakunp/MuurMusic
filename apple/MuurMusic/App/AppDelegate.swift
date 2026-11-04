import Foundation

#if os(iOS)
import UIKit
import MuurCore

/// Forwards background URLSession events (offline downloads) and configures defaults.
final class MuurAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            let handled = MuurEnvironment.shared?.downloads
                .handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler) ?? false
            if !handled { completionHandler() }
        }
    }
}
#endif

#if os(macOS)
import AppKit

/// Keeps the app alive when the main window closes (mini player / Now Playing stay usable).
final class MuurMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
#endif
