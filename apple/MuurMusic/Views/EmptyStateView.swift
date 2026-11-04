import SwiftUI

/// Friendly empty state with a bundled cat illustration.
struct EmptyStateView: View {
    enum Illustration {
        case library
        case search
        case offline
        case none

        var assetName: String? {
            switch self {
            case .library: return "EmptyLibrary"
            case .search: return "EmptySearch"
            case .offline: return "Offline"
            case .none: return nil
            }
        }
    }

    var illustration: Illustration = .library
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            if let assetName = illustration.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 190, maxHeight: 150)
                    .accessibilityHidden(true)
            } else {
                PawPrintShape()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
