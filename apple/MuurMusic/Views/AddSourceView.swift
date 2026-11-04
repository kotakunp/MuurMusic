import SwiftUI
import UniformTypeIdentifiers
import MuurCore
#if os(macOS)
import AppKit
#endif

/// Add or edit a music source. Handles plain host forms, WebDAV presets,
/// OAuth sign-in and the Plex PIN flow.
struct AddSourceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let editing: SourceConfig?

    init(editing: SourceConfig? = nil) {
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? .smb)
    }

    // Common fields
    @State private var kind: SourceKind
    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var basePath = ""
    @State private var username = ""
    @State private var password = ""

    // Options
    @State private var useTLS = true
    @State private var allowInsecureTLS = false
    @State private var smbShare = ""
    @State private var smbDomain = ""
    @State private var ftpTLSMode = "explicit"
    @State private var sftpAuth = "password"
    @State private var privateKey = ""
    @State private var privateKeyPassphrase = ""
    @State private var s3Region = ""
    @State private var s3PathStyle = true
    @State private var subsonicLegacy = false
    @State private var webdavPreset: WebDAVPreset = .generic
    @State private var upnpDescriptionURL = ""

    // Local folder
    @State private var localFolderPath = ""
    @State private var isPickingFolder = false

    // Flow state
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isSigningIn = false
    @State private var plexPIN: PlexPIN?
    @State private var plexServers: [PlexServer]?
    @State private var plexToken = ""

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    kindPicker
                }

                switch kind {
                case .local, .iCloud:
                    localSection
                case .dropbox, .googleDrive, .oneDrive, .box, .pCloud:
                    oauthSection
                case .plex:
                    plexSection
                default:
                    hostForm
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "Add Source" : "Edit Source")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if showsSaveButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(editing == nil ? "Add" : "Save") { save() }
                            .disabled(!canSave || isSaving)
                    }
                }
            }
            .disabled(isSaving)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .onAppear(perform: prefill)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let urls) = result, let url = urls.first {
                localFolderPath = url.path
                if name.isEmpty { name = url.lastPathComponent }
            }
        }
    }

    // MARK: Kind picker

    private var kindPicker: some View {
        Section("Type") {
            Picker("Source type", selection: $kind) {
                ForEach(SourceKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                }
            }
            .labelsHidden()
            .onChange(of: kind) { _, newKind in
                if name.isEmpty { name = newKind.displayName }
                if portText.isEmpty, let port = newKind.defaultPort { portText = String(port) }
            }
        }
    }

    // MARK: Local

    private var localSection: some View {
        Group {
            Section("Folder") {
                HStack {
                    Text(localFolderPath.isEmpty ? "No folder chosen" : localFolderPath)
                        .font(.callout)
                        .foregroundStyle(localFolderPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickFolder() }
                }
                Text("Picked folders are also watched for changes and rescanned automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Name", text: $name)
            }
        }
    }

    // MARK: OAuth

    private var oauthSection: some View {
        Section(kind.displayName) {
            if let provider = OAuthProvider(kind: kind) {
                if provider.isConfigured {
                    Button {
                        signIn(provider)
                    } label: {
                        HStack {
                            if isSigningIn {
                                PawProgressView(pawSize: 12)
                            }
                            Text(isSigningIn ? "Waiting for sign-in…" : "Sign in with \(provider.displayName)")
                        }
                    }
                    .disabled(isSigningIn)
                    Text("Sign-in opens your browser and returns here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Add \(provider.clientIDKey) to Secrets.xcconfig (see BUILD.md), rebuild, then sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Plex

    private var plexSection: some View {
        Group {
            if let servers = plexServers {
                Section("Choose a Server") {
                    ForEach(servers) { server in
                        Button {
                            finishPlex(server)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name)
                                Text(server.isOwned ? "Owned" : "Shared")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let pin = plexPIN {
                Section("Sign in to Plex") {
                    Text("Code: \(pin.code)")
                        .font(.title3.monospaced().weight(.bold))
                    Text("A browser window opened. Authorize MuurMusic and come back — this page updates by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        PawProgressView(pawSize: 12)
                        Text("Waiting for Plex…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Plex Again") {
                        openURL(PlexAuthenticator().authURL(for: pin))
                    }
                }
            } else {
                Section("Plex") {
                    Button {
                        startPlex()
                    } label: {
                        Text("Sign in with Plex")
                    }
                    Text("Uses the official plex.tv PIN flow — your password never touches the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Host-based form

    @ViewBuilder
    private var hostForm: some View {
        Section(kind.displayName) {
            TextField("Name", text: $name)

            if kind == .webdav {
                Picker("Provider", selection: $webdavPreset) {
                    ForEach(WebDAVPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .onChange(of: webdavPreset) { _, preset in
                    if let fixed = preset.fixedHost { host = fixed }
                    useTLS = preset.defaultUsesTLS
                    if let port = preset.defaultPort { portText = String(port) }
                }
                Text(webdavPreset.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if kind == .upnp {
                TextField("Description URL", text: $upnpDescriptionURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                Text("DLNA servers are easiest to add from “Available Devices” on the Sources screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if kind == .webdav && webdavPreset.fixedHost != nil {
                // Host fixed by preset.
            } else {
                TextField("Host", text: $host)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }

            if kind != .upnp, showsPort {
                TextField("Port (default \(kind.defaultPort.map(String.init) ?? "443"))", text: $portText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
            if showsPath {
                TextField(kind == .s3 ? "Bucket / Path" : "Path (optional)", text: $basePath)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }

        credentialsSection
        optionsSection

        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    if isTesting { PawProgressView(pawSize: 12) }
                    Text(isTesting ? "Testing…" : "Test Connection")
                }
            }
            .disabled(isTesting)
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        switch kind {
        case .smb, .ftp, .subsonic, .jellyfin, .emby:
            Section("Credentials") {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField("Password", text: $password)
                if editing != nil {
                    Text("Leave the password empty to keep the saved one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .webdav:
            Section("Credentials") {
                TextField("Username / E-mail", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField("Password / App password", text: $password)
            }
        case .sftp:
            Section("Credentials") {
                TextField("Username", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Picker("Authentication", selection: $sftpAuth) {
                    Text("Password").tag("password")
                    Text("Private Key").tag("key")
                }
                if sftpAuth == "password" {
                    SecureField("Password", text: $password)
                } else {
                    TextField("Private key (PEM)", text: $privateKey, axis: .vertical)
                        .lineLimit(3...6)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    SecureField("Key passphrase (optional)", text: $privateKeyPassphrase)
                }
            }
        case .s3:
            Section("Credentials") {
                TextField("Access Key ID", text: $username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SecureField("Secret Access Key", text: $password)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        switch kind {
        case .smb:
            Section("Options") {
                TextField("Share name", text: $smbShare)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("Domain (optional)", text: $smbDomain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        case .webdav, .sftp:
            Section("Options") {
                Toggle("Use TLS (HTTPS/SSH)", isOn: $useTLS)
                Toggle("Allow self-signed certificates", isOn: $allowInsecureTLS)
            }
        case .ftp:
            Section("Options") {
                Picker("TLS", selection: $ftpTLSMode) {
                    Text("Off").tag("off")
                    Text("Explicit (AUTH TLS)").tag("explicit")
                    Text("Implicit").tag("implicit")
                }
                Toggle("Allow self-signed certificates", isOn: $allowInsecureTLS)
            }
        case .s3:
            Section("Options") {
                TextField("Region", text: $s3Region)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Toggle("Path-style URLs (MinIO etc.)", isOn: $s3PathStyle)
            }
        case .subsonic:
            Section("Options") {
                Toggle("Use TLS (HTTPS)", isOn: $useTLS)
                Toggle("Legacy password auth (older servers)", isOn: $subsonicLegacy)
            }
        case .jellyfin, .emby:
            Section("Options") {
                Toggle("Use TLS (HTTPS)", isOn: $useTLS)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Logic

    private var showsPort: Bool {
        switch kind {
        case .smb, .ftp, .sftp, .webdav, .s3, .subsonic, .jellyfin, .emby: return true
        default: return false
        }
    }

    private var showsPath: Bool {
        switch kind {
        case .webdav, .smb, .ftp, .sftp, .s3: return true
        default: return false
        }
    }

    private var showsSaveButton: Bool {
        switch kind {
        case .dropbox, .googleDrive, .oneDrive, .box, .pCloud, .plex:
            return false
        default:
            return true
        }
    }

    private var canSave: Bool {
        switch kind {
        case .local, .iCloud:
            return !localFolderPath.isEmpty
        case .upnp:
            return !upnpDescriptionURL.isEmpty
        case .webdav:
            return webdavPreset.fixedHost != nil || !host.isEmpty
        default:
            return !host.isEmpty
        }
    }

    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            localFolderPath = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
        #else
        isPickingFolder = true
        #endif
    }

    private func makeConfig() -> SourceConfig {
        var config = editing ?? SourceConfig(kind: kind, name: name)
        config.kind = kind
        config.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : name.trimmingCharacters(in: .whitespaces)
        config.host = host.trimmingCharacters(in: .whitespaces)
        config.port = Int(portText) ?? kind.defaultPort
        config.username = username.trimmingCharacters(in: .whitespaces)
        var options = config.options

        switch kind {
        case .local, .iCloud:
            config.host = ""
            config.port = nil
            config.basePath = localFolderPath
        case .upnp:
            config.host = ""
            config.port = nil
            config.basePath = ""
            options[SourceConfig.OptionKey.upnpDescriptionURL] = upnpDescriptionURL.trimmingCharacters(in: .whitespaces)
        case .webdav:
            options[SourceConfig.OptionKey.webdavPreset] = webdavPreset.rawValue
            options[SourceConfig.OptionKey.useTLS] = useTLS ? "1" : "0"
            options[SourceConfig.OptionKey.allowInsecureTLS] = allowInsecureTLS ? "1" : "0"
            if webdavPreset.fixedHost != nil {
                config.host = webdavPreset.fixedHost ?? config.host
            }
            config.basePath = basePath
        case .smb:
            options[SourceConfig.OptionKey.smbShare] = smbShare
            options[SourceConfig.OptionKey.smbDomain] = smbDomain
            config.basePath = basePath
        case .ftp:
            options[SourceConfig.OptionKey.ftpTLSMode] = ftpTLSMode
            options[SourceConfig.OptionKey.allowInsecureTLS] = allowInsecureTLS ? "1" : "0"
            config.basePath = basePath
        case .sftp:
            options[SourceConfig.OptionKey.useTLS] = "1"
            options[SourceConfig.OptionKey.allowInsecureTLS] = allowInsecureTLS ? "1" : "0"
            options[SourceConfig.OptionKey.sftpAuth] = sftpAuth
            config.basePath = basePath
        case .s3:
            options[SourceConfig.OptionKey.s3Region] = s3Region
            options[SourceConfig.OptionKey.s3PathStyle] = s3PathStyle ? "1" : "0"
            config.basePath = basePath
        case .subsonic:
            options[SourceConfig.OptionKey.useTLS] = useTLS ? "1" : "0"
            options[SourceConfig.OptionKey.subsonicLegacyAuth] = subsonicLegacy ? "1" : "0"
            config.basePath = ""
        case .jellyfin, .emby:
            options[SourceConfig.OptionKey.useTLS] = useTLS ? "1" : "0"
            config.basePath = ""
        case .dropbox, .googleDrive, .oneDrive, .box, .pCloud, .plex:
            break
        }
        config.options = options
        return config
    }

    private func makeSecrets() -> SourceSecrets? {
        switch kind {
        case .s3:
            if username.isEmpty && password.isEmpty { return nil }
            return SourceSecrets(password: nil, secretAccessKey: password.isEmpty ? nil : password)
        case .sftp:
            if sftpAuth == "key" {
                if privateKey.isEmpty { return nil }
                return SourceSecrets(privateKey: privateKey,
                                     privateKeyPassphrase: privateKeyPassphrase.isEmpty ? nil : privateKeyPassphrase)
            }
            if password.isEmpty { return nil }
            return SourceSecrets(password: password)
        default:
            if password.isEmpty { return nil }
            return SourceSecrets(password: password)
        }
    }

    private func save() {
        var config = makeConfig()
        if kind == .webdav {
            webdavPreset.apply(to: &config)
            if !host.isEmpty && webdavPreset.fixedHost == nil { config.host = host.trimmingCharacters(in: .whitespaces) }
        }
        let secrets = makeSecrets()
        isSaving = true
        Task {
            do {
                try await model.environment.sources.save(config, secrets: secrets)
                if kind == .local || kind == .iCloud, !localFolderPath.isEmpty {
                    _ = try? await model.environment.scanner.addFolder(url: URL(fileURLWithPath: localFolderPath))
                }
                model.showToast(.success("Saved \(config.name)", systemImage: "checkmark.circle.fill"))
                dismiss()
            } catch {
                model.showError(error)
                isSaving = false
            }
        }
    }

    private func testConnection() {
        let config = makeConfig()
        let secrets = makeSecrets() ?? SourceSecrets()
        isTesting = true
        Task {
            do {
                let items = try await model.environment.sources.test(config, secrets: secrets)
                model.showToast(.success("Connected — found \(items.count) items", systemImage: "checkmark.circle.fill"))
            } catch {
                model.showError(error)
            }
            isTesting = false
        }
    }

    private func signIn(_ provider: OAuthProvider) {
        isSigningIn = true
        Task {
            do {
                let result = try await OAuthManager.shared.signIn(provider)
                var config = SourceConfig(kind: provider.kind, name: result.accountName ?? provider.displayName)
                config.options[SourceConfig.OptionKey.accountName] = result.accountName ?? ""
                try await model.environment.sources.save(config, secrets: SourceSecrets(oauth: result.tokens))
                model.showToast(.success("Connected \(provider.displayName)", systemImage: "checkmark.circle.fill"))
                dismiss()
            } catch {
                model.showError(error)
            }
            isSigningIn = false
        }
    }

    private func startPlex() {
        Task {
            do {
                let authenticator = PlexAuthenticator()
                let pin = try await authenticator.createPIN()
                plexPIN = pin
                openURL(authenticator.authURL(for: pin))
                let token = try await authenticator.waitForToken(pin)
                let servers = try await authenticator.servers(accountToken: token)
                plexToken = token
                if servers.count == 1, let server = servers.first {
                    finishPlex(server)
                } else if servers.isEmpty {
                    model.showError("No Plex servers found on this account.")
                    plexPIN = nil
                } else {
                    plexServers = servers
                }
            } catch {
                model.showError(error)
                plexPIN = nil
            }
        }
    }

    private func finishPlex(_ server: PlexServer) {
        Task {
            do {
                let authenticator = PlexAuthenticator()
                guard let url = await authenticator.bestConnection(for: server) else {
                    model.showError("No reachable connection to \(server.name).")
                    return
                }
                var config = authenticator.makeConfig(for: server, url: url)
                if config.name.isEmpty { config.name = server.name }
                try await model.environment.sources.save(config, secrets: SourceSecrets(token: server.accessToken))
                model.showToast(.success("Connected \(server.name)", systemImage: "checkmark.circle.fill"))
                dismiss()
            } catch {
                model.showError(error)
            }
        }
    }

    private func prefill() {
        guard let config = editing else {
            if name.isEmpty { name = kind.displayName }
            return
        }
        name = config.name
        host = config.host
        portText = config.port.map(String.init) ?? ""
        basePath = config.basePath
        username = config.username
        useTLS = config.useTLS
        allowInsecureTLS = config.allowInsecureTLS
        smbShare = config.option(SourceConfig.OptionKey.smbShare) ?? ""
        smbDomain = config.option(SourceConfig.OptionKey.smbDomain) ?? ""
        ftpTLSMode = config.option(SourceConfig.OptionKey.ftpTLSMode) ?? "explicit"
        sftpAuth = config.option(SourceConfig.OptionKey.sftpAuth) ?? "password"
        s3Region = config.option(SourceConfig.OptionKey.s3Region) ?? ""
        s3PathStyle = config.option(SourceConfig.OptionKey.s3PathStyle) != "0"
        subsonicLegacy = config.flag(SourceConfig.OptionKey.subsonicLegacyAuth)
        webdavPreset = WebDAVPreset(rawValue: config.option(SourceConfig.OptionKey.webdavPreset) ?? "") ?? .generic
        upnpDescriptionURL = config.option(SourceConfig.OptionKey.upnpDescriptionURL) ?? ""
        if kind == .local || kind == .iCloud {
            localFolderPath = config.basePath
        }
    }
}
