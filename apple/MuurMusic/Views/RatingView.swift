import SwiftUI

/// Five-star rating control. Tapping the current rating clears it.
struct RatingView: View {
    let rating: Int
    var starSize: CGFloat = 14
    var onRate: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: starSize))
                    .foregroundStyle(star <= rating ? MuurTheme.accentAmber : Color.secondary.opacity(0.5))
                    .onTapGesture {
                        guard let onRate else { return }
                        onRate(star == rating ? 0 : star)
                    }
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                    .accessibilityAddTraits(onRate == nil ? [] : .isButton)
            }
        }
        .accessibilityElement(children: onRate == nil ? .combine : .ignore)
        .accessibilityLabel("Rating \(rating) of 5")
    }
}
