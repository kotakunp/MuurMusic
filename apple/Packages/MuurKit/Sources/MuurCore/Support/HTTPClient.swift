import Foundation

/// URLSession wrapper with per-client credentials, optional self-signed TLS acceptance,
/// cancellation and download progress. Used by every HTTP based source.
public final class HTTPClient: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = HTTPClient()
    public static let userAgent = "MuurMusic/1.0 ( https://muur.app )"

    private struct DownloadState {
        var destination: URL
        var progress: (@Sendable (Int64, Int64) -> Void)?
        var continuation: CheckedContinuation<HTTPURLResponse, Error>?
        var moveError: Error?
    }

    private var session: URLSession!
    private let allowInsecureTLS: Bool
    private let credential: LockedValue<URLCredential?>
    private let downloads = LockedValue<[Int: DownloadState]>([:])

    public init(configuration: URLSessionConfiguration = .default, allowInsecureTLS: Bool = false, credential: URLCredential? = nil) {
        self.allowInsecureTLS = allowInsecureTLS
        self.credential = LockedValue(credential)
        super.init()
        let config = configuration
        config.httpAdditionalHeaders = (config.httpAdditionalHeaders ?? [:]).merging(["User-Agent": HTTPClient.userAgent]) { current, _ in current }
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.muur.http"
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    public func setCredential(_ credential: URLCredential?) {
        self.credential.set(credential)
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: Requests

    /// Performs a request and returns the body. Non-2xx statuses throw `MuurError.http` unless `validate` is false.
    public func data(for request: URLRequest, validate: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw MuurError.cancelled
        } catch let error as URLError {
            throw MuurError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MuurError.protocolError("Not an HTTP response")
        }
        if validate && !(200..<300).contains(http.statusCode) {
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MuurError.authenticationFailed("HTTP \(http.statusCode) \(message)")
            }
            throw MuurError.http(status: http.statusCode, message: message)
        }
        return (data, http)
    }

    public func data(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await data(for: request).0
    }

    public func json<T: Decodable>(_ type: T.Type, for request: URLRequest, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let (data, _) = try await data(for: request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MuurError.invalidData("\(T.self): \(error.localizedDescription)")
        }
    }

    /// Downloads `request` to `destination` (overwriting), reporting `(received, expected)` bytes.
    @discardableResult
    public func download(_ request: URLRequest, to destination: URL,
                         progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> HTTPURLResponse {
        let task = session.downloadTask(with: request)
        let identifier = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                downloads.mutate {
                    $0[identifier] = DownloadState(destination: destination, progress: progress, continuation: continuation, moveError: nil)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Delegate

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    private func handle(challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            if allowInsecureTLS, let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }
        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM || method == NSURLAuthenticationMethodDefault {
            if challenge.previousFailureCount == 0, let credential = credential.get() {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let callback = downloads.get()[downloadTask.taskIdentifier]?.progress
        callback?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let state = downloads.get()[downloadTask.taskIdentifier] else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: state.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: state.destination.path) {
                try fm.removeItem(at: state.destination)
            }
            try fm.moveItem(at: location, to: state.destination)
        } catch {
            downloads.mutate { $0[downloadTask.taskIdentifier]?.moveError = error }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = downloads.mutate({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        guard let continuation = state.continuation else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: MuurError.cancelled)
            } else {
                continuation.resume(throwing: MuurError.network(error.localizedDescription))
            }
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: MuurError.protocolError("Not an HTTP response"))
            return
        }
        if !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 {
                continuation.resume(throwing: MuurError.authenticationFailed("HTTP \(http.statusCode)"))
            } else {
                continuation.resume(throwing: MuurError.http(status: http.statusCode, message: ""))
            }
            return
        }
        if let moveError = state.moveError {
            continuation.resume(throwing: MuurError.io(moveError.localizedDescription))
            return
        }
        continuation.resume(returning: http)
    }
}

extension URLRequest {
    /// Convenience initializer setting method, headers and body.
    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.init(url: url)
        self.httpMethod = method
        for (key, value) in headers {
            self.setValue(value, forHTTPHeaderField: key)
        }
        self.httpBody = body
    }
}

extension URLComponents {
    /// Sets query items from a dictionary, sorted by name for deterministic URLs.
    public mutating func setQuery(_ items: [String: String]) {
        queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

/// application/x-www-form-urlencoded body encoding.
public enum FormEncoding {
    public static func encode(_ fields: [String: String]) -> Data {
        let body = fields.sorted { $0.key < $1.key }
            .map { "\(PathUtils.rfc3986Encode($0.key))=\(PathUtils.rfc3986Encode($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
