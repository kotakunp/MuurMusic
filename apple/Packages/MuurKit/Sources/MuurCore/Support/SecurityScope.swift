import Foundation

/// Creates and resolves security-scoped bookmarks and keeps folders accessible for the app's lifetime.
public final class SecurityScopeManager: @unchecked Sendable {
    public static let shared = SecurityScopeManager()

    private let accessed = LockedValue<[String: URL]>([:])

    public init() {}

    /// Bookmark data for a user-picked URL (document picker / NSOpenPanel).
    public func makeBookmark(for url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves bookmark data. `isStale` is set when the bookmark should be re-created.
    public func resolve(bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale)
    }

    /// Resolves a bookmark and starts (long-lived) security-scoped access.
    @discardableResult
    public func startAccessing(bookmark: Data, key: String) throws -> URL {
        if let existing = accessed.get()[key] { return existing }
        let (url, _) = try resolve(bookmark: bookmark)
        _ = url.startAccessingSecurityScopedResource()
        accessed.mutate { $0[key] = url }
        return url
    }

    public func stopAccessing(key: String) {
        if let url = accessed.mutate({ $0.removeValue(forKey: key) }) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// All URLs currently being accessed.
    public var accessedURLs: [URL] { Array(accessed.get().values) }
}

/// iCloud Drive helpers.
public enum UbiquityHelper {
    /// `true` when the item is an iCloud item that is not downloaded locally yet.
    public static func needsDownload(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") && name.hasSuffix(".icloud") { return true }
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current
    }

    /// Real file URL for an `.name.icloud` placeholder.
    public static func resolvePlaceholder(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix(".") && name.hasSuffix(".icloud") else { return url }
        let realName = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(realName)
    }

    /// Triggers a download of a non-local iCloud item.
    public static func startDownload(_ url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: resolvePlaceholder(url))
        } catch {
            Log.sources.error("iCloud download request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Requests the download and waits (polling) until the item is local or `timeout` elapses.
    public static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 600,
                                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let real = resolvePlaceholder(url)
        guard needsDownload(url) || needsDownload(real) else { return real }
        startDownload(real)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            var probe = real
            probe.removeAllCachedResourceValues()
            if !needsDownload(probe) && FileManager.default.fileExists(atPath: probe.path) {
                progress?(1)
                return probe
            }
            if let values = try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]),
               let error = values.ubiquitousItemDownloadingError {
                throw MuurError.io(error.localizedDescription)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw MuurError.network("Timed out waiting for iCloud Drive download")
    }
}
