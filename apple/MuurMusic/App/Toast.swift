import SwiftUI

/// A short message shown at the top of the screen (errors, confirmations).
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

/// Presents a toast as a glass capsule below the top edge; auto-dismisses. The top edge keeps it
/// clear of the tab bar and the mini player.
struct ToastOverlay: ViewModifier {
    @Binding var toast: MuurToast?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast {
                HStack(spacing: 10) {
                    Image(systemName: toast.systemImage)
                        .foregroundStyle(toast.isError ? AnyShapeStyle(MuurTheme.danger) : AnyShapeStyle(.tint))
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .muurGlass(in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture {
                    withAnimation { self.toast = nil }
                }
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { self.toast = nil }
                }
                .accessibilityLabel(toast.message)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toast)
    }
}

extension View {
    func muurToast(_ toast: Binding<MuurToast?>) -> some View {
        modifier(ToastOverlay(toast: toast))
    }
}
