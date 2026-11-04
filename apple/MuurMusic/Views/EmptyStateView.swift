import SwiftUI

/// Empty state built on the system's ContentUnavailableView.
struct EmptyStateView: View {
    enum Illustration {
        case library
        case search
        case offline
        case none

        var systemImage: String {
            switch self {
            case .library: return "music.note"
            case .search: return "magnifyingglass"
            case .offline: return "wifi.slash"
            case .none: return "pawprint.fill"
            }
        }
    }

    var illustration: Illustration = .library
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Overrides the illustration's symbol.
    var systemImage: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage ?? illustration.systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
        }
    }
}
