import Foundation
import GRDB
import Combine

/// An `ObservableObject` that keeps `value` in sync with a database fetch. Use from SwiftUI:
///
/// ```swift
/// @StateObject var albums = ObservedQuery(database: env.database, initial: []) { db in
///     try LibraryQueries.albums(db)
/// }
/// ```
@MainActor
public final class ObservedQuery<Value: Sendable>: ObservableObject {
    @Published public private(set) var value: Value
    @Published public private(set) var error: Error?
    @Published public private(set) var isLoaded = false

    private let reader: any DatabaseReader
    private var fetch: @Sendable (Database) throws -> Value
    private var cancellable: AnyDatabaseCancellable?

    public init(database: MuurDatabase, initial: Value, fetch: @escaping @Sendable (Database) throws -> Value) {
        self.reader = database.reader
        self.value = initial
        self.fetch = fetch
        start()
    }

    /// Replaces the fetch (e.g. after the sort order changed) and restarts observation.
    public func update(_ fetch: @escaping @Sendable (Database) throws -> Value) {
        self.fetch = fetch
        start()
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    private func start() {
        cancellable?.cancel()
        cancellable = ValueObservation.tracking(fetch).start(
            in: reader,
            onError: { [weak self] error in
                Log.database.error("Observation failed: \(error.localizedDescription, privacy: .public)")
                self?.error = error
            },
            onChange: { [weak self] newValue in
                guard let self else { return }
                self.value = newValue
                self.error = nil
                self.isLoaded = true
            })
    }
}
