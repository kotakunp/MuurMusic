import Foundation
import MuurWidgetKitSupport

/// File system locations used by MuurKit. All directories are created on demand by `createDirectories()`.
public struct AppPaths: Sendable {
    public let appGroupIdentifier: String
    /// The user-visible Documents folder (Files app / Finder file sharing on iOS).
    public let documents: URL
    /// `Documents/Music`: default import folder and the Wi-Fi transfer root.
    public let musicFolder: URL
    /// Private Application Support folder.
    public let applicationSupport: URL
    public let caches: URL

    public init(appGroupIdentifier: String = MuurAppGroup.identifier) {
        self.appGroupIdentifier = appGroupIdentifier
        let fm = FileManager.default
        #if os(macOS)
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documents = docs
        self.musicFolder = music.appendingPathComponent("MuurMusic", isDirectory: true)
        #else
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.documents = docs
        self.musicFolder = docs.appendingPathComponent("Music", isDirectory: true)
        #endif
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.applicationSupport = support.appendingPathComponent("MuurMusic", isDirectory: true)
        self.caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MuurMusic", isDirectory: true)
    }

    public var databaseURL: URL { applicationSupport.appendingPathComponent("library.sqlite") }
    public var artworkDirectory: URL { applicationSupport.appendingPathComponent("Artwork", isDirectory: true) }
    public var thumbnailDirectory: URL { caches.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var lyricsCacheDirectory: URL { caches.appendingPathComponent("Lyrics", isDirectory: true) }
    /// LRU cache of recently streamed remote songs.
    public var audioCacheDirectory: URL { caches.appendingPathComponent("AudioCache", isDirectory: true) }
    /// Offline downloads (kept, not purgeable by the OS).
    public var downloadsDirectory: URL { applicationSupport.appendingPathComponent("Downloads", isDirectory: true) }
    public var resumeDataDirectory: URL { applicationSupport.appendingPathComponent("ResumeData", isDirectory: true) }
    public var stateDirectory: URL { applicationSupport.appendingPathComponent("State", isDirectory: true) }
    public var archiveExtractionDirectory: URL { caches.appendingPathComponent("Archives", isDirectory: true) }
    public var temporaryDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MuurMusic", isDirectory: true) }
    public var queueStateURL: URL { stateDirectory.appendingPathComponent("queue.json") }
    public var widgetStore: WidgetSharedStore { WidgetSharedStore(appGroupIdentifier: appGroupIdentifier) }

    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [musicFolder, applicationSupport, caches, artworkDirectory, thumbnailDirectory, lyricsCacheDirectory,
                    audioCacheDirectory, downloadsDirectory, resumeDataDirectory, stateDirectory,
                    archiveExtractionDirectory, temporaryDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var downloads = downloadsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? downloads.setResourceValues(values)
    }

    /// Maps a stored absolute file path onto the current container. iOS changes the
    /// container path on app updates, so paths under Documents or Application Support are
    /// re-rooted when the stored location no longer exists.
    public func resolveStoredFileURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        let path = url.path
        let anchors: [(String, URL)] = [
            ("/Documents/", documents),
            ("/Library/Application Support/MuurMusic/", applicationSupport),
            ("/Library/Caches/MuurMusic/", caches),
        ]
        for (marker, root) in anchors {
            if let range = path.range(of: marker) {
                let relative = String(path[range.upperBound...])
                let candidate = root.appendingPathComponent(relative)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return url
    }
}
