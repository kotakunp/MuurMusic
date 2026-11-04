import Foundation
import os

/// Central `os.Logger` instances for MuurKit. Never log credentials or tokens.
public enum Log {
    public static let subsystem = "app.muur.music"
    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let sources = Logger(subsystem: subsystem, category: "sources")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let downloads = Logger(subsystem: subsystem, category: "downloads")
    public static let lyrics = Logger(subsystem: subsystem, category: "lyrics")
    public static let metadata = Logger(subsystem: subsystem, category: "metadata")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let dsp = Logger(subsystem: subsystem, category: "dsp")
    public static let transfer = Logger(subsystem: subsystem, category: "wifi-transfer")
    public static let discovery = Logger(subsystem: subsystem, category: "discovery")
}

/// Errors surfaced by MuurKit. All cases carry user-presentable descriptions.
public enum MuurError: LocalizedError, Sendable, Equatable {
    case notConfigured(String)
    case unsupported(String)
    case notFound(String)
    case network(String)
    case http(status: Int, message: String)
    case authenticationFailed(String)
    case invalidData(String)
    case protocolError(String)
    case io(String)
    case cancelled
    case offline

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let what): return "\(what) is not configured."
        case .unsupported(let what): return "\(what) is not supported."
        case .notFound(let what): return "\(what) could not be found."
        case .network(let message): return "Network error: \(message)"
        case .http(let status, let message):
            return message.isEmpty ? "Server returned HTTP \(status)." : "Server returned HTTP \(status): \(message)"
        case .authenticationFailed(let message): return "Sign-in failed: \(message)"
        case .invalidData(let message): return "Unexpected data: \(message)"
        case .protocolError(let message): return "Protocol error: \(message)"
        case .io(let message): return "File error: \(message)"
        case .cancelled: return "The operation was cancelled."
        case .offline: return "Offline mode is on."
        }
    }
}
