import Foundation

/// `muurmusic://` deep links used by widgets, CarPlay and App Intents.
enum DeepLink: Equatable {
    case nowPlaying
    case playPause
    case next
    case previous
    case resume
    case playlist(id: Int64)
    case search(String?)

    static let scheme = "muurmusic"

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme == scheme, let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "nowplaying": return .nowPlaying
        case "playpause", "toggle": return .playPause
        case "next": return .next
        case "previous": return .previous
        case "resume": return .resume
        case "playlist":
            guard let first = path.first, let id = Int64(first) else { return nil }
            return .playlist(id: id)
        case "search":
            let text = path.first?.removingPercentEncoding
            return .search(text)
        default:
            // OAuth redirects (host "oauth") are consumed by MuurEnvironment.
            return nil
        }
    }

    var url: URL {
        switch self {
        case .nowPlaying: return URL(string: "muurmusic://nowplaying")!
        case .playPause: return URL(string: "muurmusic://playpause")!
        case .next: return URL(string: "muurmusic://next")!
        case .previous: return URL(string: "muurmusic://previous")!
        case .resume: return URL(string: "muurmusic://resume")!
        case .playlist(let id): return URL(string: "muurmusic://playlist/\(id)")!
        case .search(let text):
            if let text, !text.isEmpty {
                return URL(string: "muurmusic://search/\(text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text)")!
            }
            return URL(string: "muurmusic://search")!
        }
    }
}
