import SwiftUI
import MuurCore

/// Track/album artwork backed by the shared ArtworkCache, with the DefaultArtwork cat as fallback.
struct ArtworkImage: View {
    @EnvironmentObject var model: AppModel
    let artworkKey: String?
    var cornerRadius: CGFloat = MuurTheme.radiusRow
    var size: Int = 300

    @State private var image: UXImage?

    var body: some View {
        ArtworkFill(image: image, cornerRadius: cornerRadius)
            .task(id: artworkKey) { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let artworkKey, !artworkKey.isEmpty else {
            image = nil
            return
        }
        let cache = model.environment.artwork
        let thumbSize = size
        let data = await Task.detached(priority: .userInitiated) {
            cache.thumbnailData(for: artworkKey, size: thumbSize)
        }.value
        guard !Task.isCancelled else { return }
        if let data, let loaded = UXImage.from(data: data) {
            image = loaded
        } else {
            image = nil
        }
    }
}

/// Artwork loaded straight from a remote URL (used for network source items).
struct RemoteArtworkImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    var cornerRadius: CGFloat = MuurTheme.radiusRow

    @State private var image: UXImage?

    var body: some View {
        ArtworkFill(image: image, cornerRadius: cornerRadius)
            .task(id: url) { await load() }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard let url else { image = nil; return }
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            image = UXImage.from(data: data)
        } catch {
            image = nil
        }
    }
}

/// A square slot filled edge to edge by the artwork (or the DefaultArtwork cat).
/// The square comes first so non-square covers are cropped to it instead of spilling
/// past the frame the caller sets.
private struct ArtworkFill: View {
    let image: UXImage?
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uxImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image("DefaultArtwork")
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
