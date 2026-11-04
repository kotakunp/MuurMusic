import Foundation
import MuurCore

public enum ShuffleMode: String, Codable, CaseIterable, Sendable { case off, on }
public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    public var next: RepeatMode {
        switch self { case .off: return .all; case .all: return .one; case .one: return .off }
    }
}

/// One queue entry; `id` survives reorders so UI lists stay stable.
public struct QueueItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var track: Track

    public init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

/// The playback queue: items in library order plus a play order used by shuffle.
/// Value type; `PlaybackController` publishes it.
public struct PlaybackQueue: Codable, Sendable, Equatable {
    public private(set) var items: [QueueItem]
    /// Indices into `items` in play order.
    public private(set) var order: [Int]
    /// Index into `order` of the current item (-1 = nothing).
    public private(set) var position: Int
    public var shuffleMode: ShuffleMode
    public var repeatMode: RepeatMode

    public init(items: [QueueItem] = [], startIndex: Int = -1, shuffleMode: ShuffleMode = .off, repeatMode: RepeatMode = .off) {
        self.items = items
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
        if startIndex >= 0 && startIndex < items.count {
            order = PlaybackQueue.makeOrder(count: items.count, startIndex: startIndex, shuffled: shuffleMode == .on)
            position = 0
        } else {
            order = Array(items.indices)
            position = items.isEmpty ? -1 : 0
        }
    }

    static func makeOrder(count: Int, startIndex: Int, shuffled: Bool) -> [Int] {
        guard shuffled else { return Array(0..<count) }
        var rest = (0..<count).filter { $0 != startIndex }
        rest.shuffle()
        return [startIndex] + rest
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public var currentItem: QueueItem? {
        guard position >= 0, position < order.count else { return nil }
        return items[order[position]]
    }

    public var currentTrack: Track? { currentItem?.track }

    /// Index into `items` of the current entry (for UI highlight).
    public var currentItemIndex: Int? {
        guard position >= 0, position < order.count else { return nil }
        return order[position]
    }

    public var nextItem: QueueItem? {
        if repeatMode == .one { return currentItem }
        let next = position + 1
        if next < order.count { return items[order[next]] }
        return repeatMode == .all ? items[order[0]] : nil
    }

    /// Items coming up in play order (current excluded). `limit` 0 = all.
    public func upNext(limit: Int = 0) -> [QueueItem] {
        guard !items.isEmpty, position >= 0, position < order.count else { return [] }
        var indices: [Int] = []
        if repeatMode == .one { indices.append(order[position]) }
        if position + 1 < order.count { indices.append(contentsOf: order[(position + 1)...]) }
        if repeatMode == .all { indices.append(contentsOf: order[0...position]) }
        let mapped = indices.map { items[$0] }
        return limit > 0 ? Array(mapped.prefix(limit)) : mapped
    }

    /// Moves to the next item in play order. Returns false when the queue is exhausted
    /// (repeat `.off` at the last item).
    @discardableResult
    public mutating func advance() -> Bool {
        guard !items.isEmpty, position >= 0 else { return false }
        if position + 1 < order.count {
            position += 1
            return true
        }
        if repeatMode == .all {
            position = 0
            return true
        }
        return false
    }

    /// Moves to the previous item (restart handled by the caller using elapsed time).
    @discardableResult
    public mutating func back() -> Bool {
        guard position > 0 else { return false }
        position -= 1
        return true
    }

    /// Jumps to the entry with `id`.
    @discardableResult
    public mutating func jump(to id: UUID) -> Bool {
        guard let itemIndex = items.firstIndex(where: { $0.id == id }),
              let orderIndex = order.firstIndex(of: itemIndex) else { return false }
        position = orderIndex
        return true
    }

    public mutating func append(_ newItems: [QueueItem]) {
        let start = items.count
        items.append(contentsOf: newItems)
        if order.isEmpty {
            order = Array(items.indices)
            if position < 0 { position = items.isEmpty ? -1 : 0 }
            return
        }
        var additions = Array(start..<items.count)
        if shuffleMode == .on { additions.shuffle() }
        order.append(contentsOf: additions)
        if position < 0 { position = 0 }
    }

    /// Inserts items right after the current one in play order.
    public mutating func insertNext(_ newItems: [QueueItem]) {
        let start = items.count
        items.append(contentsOf: newItems)
        let insertionPoint = position + 1
        order.insert(contentsOf: Array(start..<items.count), at: min(insertionPoint, order.count))
        if position < 0 { position = 0 }
    }

    public mutating func remove(ids: Set<UUID>) {
        let removedIndices = Set(items.indices.filter { ids.contains(items[$0].id) })
        guard !removedIndices.isEmpty else { return }
        let currentID = currentItem?.id
        items = items.enumerated().compactMap { removedIndices.contains($0.offset) ? nil : $0.element }
        var remap: [Int: Int] = [:]
        var newIndex = 0
        for old in 0..<(items.count + removedIndices.count) where !removedIndices.contains(old) {
            remap[old] = newIndex
            newIndex += 1
        }
        order = order.compactMap { remap[$0] }
        if let currentID, let itemIndex = items.firstIndex(where: { $0.id == currentID }), let orderIndex = order.firstIndex(of: itemIndex) {
            position = orderIndex
        } else {
            position = min(position, order.count - 1)
        }
        if items.isEmpty { position = -1 }
    }

    /// Moves entries in play order (drag & drop in the queue UI moves what you see).
    public mutating func moveInPlayOrder(from source: IndexSet, to destination: Int) {
        guard !items.isEmpty else { return }
        var visible = Array(order[(position + 1)...])
        let moving = source.map { visible[$0] }
        visible.remove(atOffsets: source)
        let clamped = min(max(0, destination - source.filter { $0 < destination }.count), visible.count)
        visible.insert(contentsOf: moving, at: clamped)
        order = Array(order[0...position]) + visible
    }

    public mutating func setShuffle(_ mode: ShuffleMode) {
        guard mode != shuffleMode else { return }
        shuffleMode = mode
        guard !items.isEmpty, let currentIndex = currentItemIndex else {
            order = Array(items.indices)
            return
        }
        if mode == .on {
            order = PlaybackQueue.makeOrder(count: items.count, startIndex: currentIndex, shuffled: true)
        } else {
            order = Array(items.indices)
        }
        position = order.firstIndex(of: currentIndex) ?? 0
    }
}

/// Persisted queue (SHARED_FORMATS queue state): written to `AppPaths.queueStateURL`.
public struct QueueState: Codable, Sendable {
    public var version: Int
    public var queue: PlaybackQueue
    /// Playback position in seconds at save time.
    public var trackPosition: Double
    public var isPlaying: Bool
    public var savedAt: Date

    public init(queue: PlaybackQueue, trackPosition: Double, isPlaying: Bool, savedAt: Date = Date(), version: Int = 1) {
        self.version = version
        self.queue = queue
        self.trackPosition = trackPosition
        self.isPlaying = isPlaying
        self.savedAt = savedAt
    }

    public static func load(from url: URL) -> QueueState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(QueueState.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
