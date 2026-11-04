import SwiftUI

/// A paw print drawn with shapes — used for loading indicators and decorative accents.
struct PawPrintShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        // Main pad
        path.addEllipse(in: CGRect(x: 0.20 * w, y: 0.42 * h, width: 0.60 * w, height: 0.55 * h))
        // Four toes along the top
        let toes: [(x: CGFloat, y: CGFloat, tw: CGFloat, th: CGFloat)] = [
            (0.00, 0.30, 0.24, 0.32),
            (0.25, 0.03, 0.24, 0.34),
            (0.52, 0.00, 0.24, 0.34),
            (0.79, 0.27, 0.21, 0.32),
        ]
        for toe in toes {
            path.addEllipse(in: CGRect(x: toe.x * w, y: toe.y * h, width: toe.tw * w, height: toe.th * h))
        }
        return path
    }
}

/// Animated row of paw prints — a cat "walking" while work happens.
struct PawProgressView: View {
    var pawSize: CGFloat = 18
    /// Nil follows the current tint.
    var color: Color? = nil
    var pawCount: Int = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.32, paused: false)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.32) % (pawCount + 1)
            HStack(spacing: pawSize * 0.85) {
                ForEach(0..<pawCount, id: \.self) { index in
                    PawPrintShape()
                        .fill(pawStyle(lit: index < step))
                        .frame(width: pawSize, height: pawSize)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -14 : 14))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private func pawStyle(lit: Bool) -> AnyShapeStyle {
        let opacity = lit ? 1.0 : 0.2
        if let color { return AnyShapeStyle(color.opacity(opacity)) }
        return AnyShapeStyle(.tint.opacity(opacity))
    }
}

/// Full-area loading indicator with paw prints.
struct LoadingView: View {
    var message: String = "Herding cats…"

    var body: some View {
        VStack(spacing: 16) {
            PawProgressView(pawSize: 24)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
