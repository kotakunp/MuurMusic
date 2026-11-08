import SwiftUI
import UniformTypeIdentifiers
import MuurCore
#if os(iOS)
import WebKit

/// One file downloaded from the in-app browser.
struct BrowserDownload: Identifiable, Equatable {
    enum State: Equatable {
        case downloading
        case importing
        case added
        case failed(String)
        case cancelled
    }

    let id: UUID
    var fileName: String
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var state: State = .downloading

    var isActive: Bool { state == .downloading || state == .importing }
    var fraction: Double { totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 1) : 0 }
}

/// A file a page wants to download, waiting for the user to confirm.
struct PendingBrowserDownload: Identifiable {
    let id = UUID()
    let fileName: String
    let expectedBytes: Int64
    /// WebKit can show it in place (an MP3 opened as a page plays in the browser).
    let canOpenInBrowser: Bool
    fileprivate let decide: (WKNavigationResponsePolicy) -> Void
}

/// The in-app browser. It lives as long as the app so the open page and running downloads survive
/// leaving the screen. Songs, playlists and ZIP files it downloads are imported into the library.
@MainActor
final class WebBrowserSession: NSObject, ObservableObject {
    let webView: WKWebView

    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var isShowingStartPage = true
    @Published private(set) var pendingDownload: PendingBrowserDownload?
    @Published private(set) var downloads: [BrowserDownload] = []

    var activeDownloadCount: Int { downloads.filter(\.isActive).count }

    private struct Record {
        let id: UUID
        let download: WKDownload
        var destination: URL?
        var progressObservation: NSKeyValueObservation?
    }

    private let importer: ([URL]) async throws -> [URL]
    private let notify: (MuurToast) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var records: [ObjectIdentifier: Record] = [:]

    init(importer: @escaping ([URL]) async throws -> [URL], notify: @escaping (MuurToast) -> Void) {
        self.importer = importer
        self.notify = notify
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        // Partial files left by downloads the app was quit during.
        try? FileManager.default.removeItem(at: Self.downloadsFolder)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    // MARK: Navigation

    /// Opens a web address, or searches the web for anything that doesn't look like one.
    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let target = Self.destination(for: text) else { return }
        open(target)
    }

    func open(_ target: URL) {
        isShowingStartPage = false
        webView.load(URLRequest(url: target))
    }

    nonisolated static func destination(for text: String) -> URL? {
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        if !text.contains(" "), text.contains(".") || text.lowercased().hasPrefix("localhost"),
           let url = URL(string: (text.lowercased().hasPrefix("localhost") ? "http://" : "https://") + text), url.host != nil {
            return url
        }
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// Back goes through the page history, then to the start page.
    var canNavigateBack: Bool { !isShowingStartPage }
    var canNavigateForward: Bool { isShowingStartPage ? url != nil : canGoForward }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            isShowingStartPage = true
        }
    }

    func goForward() {
        if isShowingStartPage {
            isShowingStartPage = false
        } else {
            webView.goForward()
        }
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func showStartPage() {
        isShowingStartPage = true
    }

    // MARK: Downloads

    func resolvePendingDownload(_ policy: WKNavigationResponsePolicy) {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        pending.decide(policy)
    }

    /// WebKit doesn't report a cancel started here through `didFailWithError`, so the row and the partial
    /// file are cleaned up directly.
    func cancel(_ id: UUID) {
        guard let (key, record) = records.first(where: { $0.value.id == id }) else { return }
        records[key] = nil
        update(id) { $0.state = .cancelled }
        let folder = record.destination?.deletingLastPathComponent()
        record.download.cancel { _ in
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
    }

    func clearFinishedDownloads() {
        downloads.removeAll { !$0.isActive }
    }

    nonisolated static var downloadsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDownloads", isDirectory: true)
    }

    nonisolated static func isImportable(_ name: String) -> Bool {
        PathUtils.isAudio(name) || PathUtils.isPlaylist(name) || PathUtils.isArchive(name)
    }

    /// The server's file name, with an extension taken from the MIME type when the name has none.
    nonisolated static func fileName(suggested: String?, response: URLResponse) -> String {
        var name = suggested ?? response.suggestedFilename ?? response.url?.lastPathComponent ?? "Download"
        if PathUtils.fileExtension(name).isEmpty, let mime = response.mimeType,
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += "." + ext
        }
        return PathUtils.sanitizeFileName(name)
    }

    private func update(_ id: UUID, _ change: (inout BrowserDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&downloads[index])
    }

    private func track(_ download: WKDownload) {
        download.delegate = self
        let item = BrowserDownload(id: UUID(), fileName: download.originalRequest?.url?.lastPathComponent ?? "Download")
        downloads.insert(item, at: 0)
        let id = item.id
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                self?.update(id) { item in
                    item.completedBytes = completed
                    item.totalBytes = total
                }
            }
        }
        records[ObjectIdentifier(download)] = Record(id: id, download: download, progressObservation: observation)
    }

    private func finish(_ record: Record) {
        guard let destination = record.destination else { return }
        let id = record.id
        update(id) { item in
            item.state = .importing
            if item.totalBytes <= 0 { item.totalBytes = max(item.completedBytes, 1) }
            item.completedBytes = item.totalBytes
        }
        Task {
            do {
                _ = try await importer([destination])
                update(id) { $0.state = .added }
                notify(.success("Added \(destination.lastPathComponent) to your library", systemImage: "arrow.down.circle.fill"))
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
                notify(.error(error))
            }
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
    }
}

extension WebBrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let target = navigationAction.request.url, let scheme = target.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            // mailto:, tel:, App Store links and the like belong to other apps.
            UIApplication.shared.open(target)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let mime = response.mimeType?.lowercased() ?? ""
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.contains("attachment")
        // Audio players inside a page don't navigate, so this only sees files opened as a page or offered as downloads.
        let isFile = isAttachment || (navigationResponse.isForMainFrame && (!navigationResponse.canShowMIMEType || mime.hasPrefix("audio/")))
        guard isFile else {
            decisionHandler(.allow)
            return
        }
        let name = Self.fileName(suggested: nil, response: response)
        guard Self.isImportable(name) else {
            if navigationResponse.canShowMIMEType && !isAttachment {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                notify(.error("“\(name)” isn't a song, playlist or ZIP file, so MuurMusic can't add it."))
            }
            return
        }
        resolvePendingDownload(.cancel)
        pendingDownload = PendingBrowserDownload(fileName: name, expectedBytes: response.expectedContentLength,
                                                 canOpenInBrowser: navigationResponse.canShowMIMEType && !isAttachment,
                                                 decide: decisionHandler)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // "Frame load interrupted": the navigation turned into a download or was cancelled on purpose.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        notify(.error(error))
    }
}

extension WebBrowserSession: WKUIDelegate {
    /// Links that open a new window load in the same view; the browser has no tabs.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

extension WebBrowserSession: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard let record = records[key] else {
            completionHandler(nil)
            return
        }
        let name = Self.fileName(suggested: suggestedFilename, response: response)
        update(record.id) { item in
            item.fileName = name
            if response.expectedContentLength > 0 { item.totalBytes = response.expectedContentLength }
        }
        guard Self.isImportable(name) else {
            update(record.id) { $0.state = .failed("Not a song, playlist or ZIP file") }
            records[key] = nil
            completionHandler(nil)
            return
        }
        let folder = Self.downloadsFolder.appendingPathComponent(record.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            update(record.id) { $0.state = .failed(error.localizedDescription) }
            records[key] = nil
            completionHandler(nil)
            return
        }
        let destination = folder.appendingPathComponent(name)
        records[key]?.destination = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let record = records.removeValue(forKey: ObjectIdentifier(download)) else { return }
        finish(record)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let record = records.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let nsError = error as NSError
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        update(record.id) { $0.state = cancelled ? .cancelled : .failed(error.localizedDescription) }
        if let destination = record.destination {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }
    }
}

// MARK: - Views

/// Hosts the session's long-lived web view.
private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// A Documents-style browser: open music sites, and songs or albums you download land in the library.
struct WebBrowserView: View {
    @ObservedObject var session: WebBrowserSession

    @State private var address = ""
    @State private var isShowingDownloads = false
    @FocusState private var isEditingAddress: Bool

    var body: some View {
        ZStack {
            WebViewContainer(webView: session.webView)
                .opacity(session.isShowingStartPage ? 0 : 1)
            if session.isShowingStartPage {
                BrowserStartPage(session: session)
            }
        }
        .overlay(alignment: .top) {
            if session.isLoading && !session.isShowingStartPage {
                ProgressView(value: session.progress)
                    .progressViewStyle(.linear)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditingAddress = false
                    session.showStartPage()
                } label: {
                    Image(systemName: "house")
                }
                .disabled(session.isShowingStartPage)
                .accessibilityLabel("Start Page")
            }
        }
        .alert(pendingTitle, isPresented: pendingBinding, presenting: session.pendingDownload) { pending in
            Button("Download") { session.resolvePendingDownload(.download) }
            if pending.canOpenInBrowser {
                Button("Open in Browser") { session.resolvePendingDownload(.allow) }
            }
            Button("Cancel", role: .cancel) { session.resolvePendingDownload(.cancel) }
        } message: { pending in
            Text(pendingMessage(pending))
        }
        .sheet(isPresented: $isShowingDownloads) {
            BrowserDownloadsView(session: session)
        }
        .onAppear { syncAddress() }
        .onChange(of: session.url) { syncAddress() }
        .onChange(of: session.isShowingStartPage) { syncAddress() }
        .onChange(of: isEditingAddress) { _, editing in
            if editing {
                address = session.isShowingStartPage ? "" : (session.url?.absoluteString ?? "")
            } else {
                syncAddress()
            }
        }
    }

    private var pageTitle: String {
        if session.isShowingStartPage { return "Browse & Download" }
        if !session.title.isEmpty { return session.title }
        return session.url?.host() ?? ""
    }

    private var pendingTitle: String {
        "Download “\(session.pendingDownload?.fileName ?? "")”?"
    }

    private var pendingBinding: Binding<Bool> {
        Binding(get: { session.pendingDownload != nil },
                set: { if !$0 { session.resolvePendingDownload(.cancel) } })
    }

    private func pendingMessage(_ pending: PendingBrowserDownload) -> String {
        let kind = PathUtils.isArchive(pending.fileName) ? "The songs inside are added to your library."
            : PathUtils.isPlaylist(pending.fileName) ? "It's added to your library as a playlist."
            : "It's added to your library."
        guard pending.expectedBytes > 0 else { return kind }
        return ByteCountFormatter.string(fromByteCount: pending.expectedBytes, countStyle: .file) + ". " + kind
    }

    private func syncAddress() {
        guard !isEditingAddress else { return }
        address = session.isShowingStartPage ? "" : (session.url?.host() ?? "")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            circleButton("chevron.backward", label: "Back", enabled: session.canNavigateBack) {
                session.goBack()
            }
            circleButton("chevron.forward", label: "Forward", enabled: session.canNavigateForward) {
                session.goForward()
            }
            addressField
            circleButton("arrow.down.circle", label: "Downloads", enabled: true) {
                isShowingDownloads = true
            }
            .overlay(alignment: .topTrailing) {
                if session.activeDownloadCount > 0 {
                    Text("\(session.activeDownloadCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.tint, in: Capsule())
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: addressIcon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search or website", text: $address)
                .focused($isEditingAddress)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(isEditingAddress ? .leading : .center)
                .onSubmit {
                    session.open(address)
                    isEditingAddress = false
                }
            if isEditingAddress {
                if !address.isEmpty {
                    Button {
                        address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear")
                }
            } else if !session.isShowingStartPage {
                Button {
                    session.reloadOrStop()
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel(session.isLoading ? "Stop" : "Reload")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .muurGlass(in: Capsule(), interactive: true)
    }

    private var addressIcon: String {
        if isEditingAddress || session.isShowingStartPage { return "magnifyingglass" }
        return session.url?.scheme == "https" ? "lock.fill" : "globe"
    }

    private func circleButton(_ systemImage: String, label: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .muurGlass(in: Circle(), interactive: true)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Suggested sites that offer music downloads.
private struct BrowserStartPage: View {
    @ObservedObject var session: WebBrowserSession

    private struct Site: Identifiable {
        let name: String
        let detail: String
        let address: String
        let systemImage: String
        var id: String { address }
    }

    private static let sites: [Site] = [
        Site(name: "Internet Archive", detail: "Free recordings, live concerts and old radio shows.",
             address: "https://archive.org/details/audio", systemImage: "building.columns.fill"),
        Site(name: "Free Music Archive", detail: "Free downloads from independent artists.",
             address: "https://freemusicarchive.org", systemImage: "music.note.house.fill"),
        Site(name: "Jamendo", detail: "Independent music shared under Creative Commons.",
             address: "https://www.jamendo.com", systemImage: "music.mic"),
        Site(name: "Bandcamp", detail: "Albums you bought, and free or name-your-price releases.",
             address: "https://bandcamp.com", systemImage: "bag.fill"),
        Site(name: "Musopen", detail: "Public-domain classical recordings.",
             address: "https://musopen.org/music/", systemImage: "pianokeys"),
        Site(name: "ccMixter", detail: "Remixes and instrumentals under Creative Commons.",
             address: "https://ccmixter.org", systemImage: "slider.horizontal.3"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.sites) { site in
                    Button {
                        if let url = URL(string: site.address) { session.open(url) }
                    } label: {
                        AddMethodRow(title: site.name, detail: site.detail, systemImage: site.systemImage)
                    }
                }
            } header: {
                Text("Music Sites")
            } footer: {
                Text("Tap a download link for a song, an album ZIP or a playlist, and MuurMusic adds it to your library. Only download music you have the right to keep.")
            }
        }
    }
}

/// Downloads started in the browser, with progress and their result.
private struct BrowserDownloadsView: View {
    @ObservedObject var session: WebBrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if session.downloads.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Songs, albums and playlists you download from websites show up here."))
                } else {
                    List(session.downloads) { item in
                        row(item)
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.downloads.contains(where: { !$0.isActive }) {
                        Button("Clear") { session.clearFinishedDownloads() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: BrowserDownload) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.fileName))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                }
                Text(status(item))
                    .font(.caption)
                    .foregroundStyle(statusColor(item))
                    .lineLimit(2)
            }
            if item.state == .downloading {
                Button {
                    session.cancel(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for name: String) -> String {
        if PathUtils.isArchive(name) { return "doc.zipper" }
        if PathUtils.isPlaylist(name) { return "music.note.list" }
        return "music.note"
    }

    private func status(_ item: BrowserDownload) -> String {
        switch item.state {
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)
            guard item.totalBytes > 0 else { return done }
            return "\(done) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))"
        case .importing: return "Adding to your library…"
        case .added: return "Added to your library"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }

    private func statusColor(_ item: BrowserDownload) -> Color {
        switch item.state {
        case .added: return .green
        case .failed: return MuurTheme.danger
        default: return .secondary
        }
    }
}
#endif
