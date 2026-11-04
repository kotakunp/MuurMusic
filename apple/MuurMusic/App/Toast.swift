import SwiftUI

/// A short message shown at the bottom of the screen (errors, confirmations).
struct MuurToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var systemImage: String
    var isError: Bool

    static func success(_ message: String, systemImage: String = "checkmark.circle.fill") -> MuurToast {
        MuurToast(message: message, systemImage: systemImage, isError: false)
    }

    static func error(_ message: String) -> MuurToast {
        MuurToast(message: message, systemImage: "exclamationmark.triangle.fill", isError: true)
    }

    static func error(_ error: Error) -> MuurToast {
        MuurToast.error(error.localizedDescription)
    }
}

/// Presents a toast at the bottom edge; auto-dismisses.
struct ToastOverlay: ViewModifier {
    @Binding var toast: MuurToast?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .foregroundStyle(toast.isError ? MuurTheme.danger : MuurTheme.accentAmber)
                    Text(toast.message)
                        .font(.subheadline)
                        .foregroundStyle(scheme.muur.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(scheme.muur.bgElevated, in: Capsule())
                .overlay(Capsule().strokeBorder(scheme.muur.bgHighlight, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture {
                    withAnimation { self.toast = nil }
                }
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { self.toast = nil }
                }
                .accessibilityLabel(toast.message)
            }
        }
        .animation(.spring(response: 0.35), value: toast)
    }
}

extension View {
    func muurToast(_ toast: Binding<MuurToast?>) -> some View {
        modifier(ToastOverlay(toast: toast))
    }
}
