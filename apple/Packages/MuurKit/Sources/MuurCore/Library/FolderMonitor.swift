import Foundation
#if os(macOS)
import CoreServices
#endif

/// Watches a directory tree and calls `handler` (debounced) after changes. Uses FSEvents on macOS and
/// `DispatchSource` file-system sources (one per directory, up to `maxDirectories`) on iOS.
public final class FolderMonitor: @unchecked Sendable {
    public let url: URL
    private let debounce: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.muur.folder-monitor")
    private var pendingWork: DispatchWorkItem?
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #else
    private var sources: [DispatchSourceFileSystemObject] = []
    private let maxDirectories = 256
    #endif

    public init(url: URL, debounce: TimeInterval = 2, handler: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.handler = handler
    }

    deinit {
        stopOnQueue()
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    fileprivate func signal() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [handler] in handler() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    #if os(macOS)
    private func startOnQueue() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FolderMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.signal()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            Log.library.error("Could not create FSEvents stream for \(self.url.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopOnQueue() {
        pendingWork?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
    #else
    private func startOnQueue() {
        guard sources.isEmpty else { return }
        var directories = [url]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while let next = enumerator.nextObject() {
                guard directories.count < maxDirectories else { break }
                guard let child = next as? URL,
                      (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                directories.append(child)
            }
        }
        for directory in directories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .delete, .rename, .extend], queue: queue)
            source.setEventHandler { [weak self] in self?.signal() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    private func stopOnQueue() {
        pendingWork?.cancel()
        for source in sources { source.cancel() }
        sources.removeAll()
    }
    #endif
}
