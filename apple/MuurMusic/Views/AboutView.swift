import SwiftUI
import MuurCore

/// About screen with version info, links and the hidden cat card.
struct AboutView: View {
    @Environment(\.openURL) private var openURL

    @State private var tapCount = 0
    @State private var showCat = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .onTapGesture {
                        tapCount += 1
                        if tapCount >= 5 {
                            tapCount = 0
                            showCat = true
                        }
                    }
                    .accessibilityLabel("MuurMusic logo")

                Text("MuurMusic")
                    .font(.title.weight(.bold))
                Text("Version \(version) • \(PlatformInfo.osName) \(PlatformInfo.osVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("A calm, open music player for your whole collection — made without ads, tracking, or accounts you didn't ask for.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                VStack(spacing: 10) {
                    Button {
                        openURL(URL(string: "https://muur.app")!)
                    } label: {
                        Label("muur.app", systemImage: "globe")
                    }
                    ShareLink(item: URL(string: "https://muur.app")!) {
                        Label("Tell a Friend", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 4) {
                    Text("Purring proudly on")
                    Image(systemName: "cat.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCat) {
            CatCardView()
        }
        #else
        .sheet(isPresented: $showCat) {
            CatCardView()
                .frame(width: 380, height: 460)
        }
        #endif
    }
}

/// The secret cat card (tap the logo five times).
struct CatCardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color(hex: "#17122B").ignoresSafeArea()
            VStack(spacing: 24) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .rotationEffect(.degrees(appeared ? 0 : -180))
                    .animation(.spring(response: 0.8, dampingFraction: 0.6), value: appeared)
                Text("You found the cat.")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(hex: "#F5F2FF"))
                Text("It was here all along, quietly organizing your music.")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#A79FC7"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    dismiss()
                } label: {
                    Text("Back to the music")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(MuurTheme.accentAmber, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { appeared = true }
    }
}
