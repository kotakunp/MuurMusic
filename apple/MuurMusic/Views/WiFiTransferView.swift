import SwiftUI
import CoreImage.CIFilterBuiltins
import MuurCore

/// Wi-Fi transfer server: start/stop, QR codes, PIN, live upload list.
struct WiFiTransferView: View {
    @EnvironmentObject var model: AppModel

    @State private var isRunning = false
    @State private var urls: [URL] = []
    @State private var uploads: [WiFiTransferUpload] = []
    @State private var receivedCount = 0
    @State private var lastError: String?

    private var server: WiFiTransferServer { model.environment.wifiTransfer }
    private var settings: MuurSettings { model.settings }

    var body: some View {
        Form {
            Section {
                Toggle("Server Running", isOn: runningBinding)
                Stepper(value: portBinding, in: 1024...65535) {
                    Text(verbatim: "Port: \(settings.wifiTransferPort)")
                }
                .disabled(isRunning)
            }

            if isRunning && !urls.isEmpty {
                Section("Open on Your Computer") {
                    ForEach(urls, id: \.absoluteString) { url in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(url.absoluteString)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer()
                                ShareLink(item: url.absoluteString) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            if let qr = qrImage(for: url.absoluteString) {
                                Image(uxCGImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 140, height: 140)
                                    .padding(8)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("QR code for \(url.absoluteString)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Text("Both devices must be on the same Wi-Fi network. Drop music files on the page — the cat drags them into your library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                // The server captures these when it starts, so they are locked while it runs.
                Group {
                    Toggle("Require PIN", isOn: requirePINBinding)
                    if settings.wifiTransferRequirePIN {
                        // Visible on purpose: the user has to read it out or type it on the computer.
                        TextField("PIN", text: pinBinding)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Text("Ask the cat nicely — or enter this PIN on the upload page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isRunning)
            } header: {
                Text("Security")
            } footer: {
                if isRunning {
                    Text("Stop the server to change the port or PIN.")
                }
            }

            if isRunning {
                Section("Uploads (\(receivedCount) received)") {
                    if uploads.isEmpty {
                        Text("No uploads yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(uploads) { upload in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(upload.fileName)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                if let message = upload.errorMessage {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(MuurTheme.danger)
                                        .accessibilityLabel(message)
                                } else if upload.isFinished {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MuurTheme.success)
                                }
                            }
                            if !upload.isFinished {
                                ProgressView(value: upload.fraction)
                                    .tint(MuurTheme.accentAmber)
                            }
                        }
                    }
                    Button("Clear Finished") {
                        server.clearFinishedUploads()
                    }
                }
            }

            if let lastError {
                Section {
                    Label(lastError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(MuurTheme.danger)
                }
            }
        }
        .formStyle(.grouped)
        .muurScreen()
        .navigationTitle("Wi-Fi Transfer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onReceive(server.$isRunning) { isRunning = $0 }
        .onReceive(server.$urls) { urls = $0 }
        .onReceive(server.$uploads) { uploads = $0.reversed() }
        .onReceive(server.$receivedFileCount) { receivedCount = $0 }
        .onReceive(server.$lastError) { lastError = $0 }
    }

    private var runningBinding: Binding<Bool> {
        Binding(
            get: { isRunning },
            set: { run in
                if run {
                    do {
                        try server.start(port: settings.wifiTransferPort)
                    } catch {
                        model.showError(error)
                    }
                } else {
                    server.stop()
                }
            }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(get: { settings.wifiTransferPort }, set: { settings.wifiTransferPort = $0 })
    }

    private var requirePINBinding: Binding<Bool> {
        Binding(
            get: { settings.wifiTransferRequirePIN },
            set: { value in
                settings.wifiTransferRequirePIN = value
                if value && settings.wifiTransferPIN.isEmpty {
                    settings.wifiTransferPIN = String(format: "%04d", Int.random(in: 0...9999))
                }
            }
        )
    }

    private var pinBinding: Binding<String> {
        Binding(get: { settings.wifiTransferPIN }, set: { settings.wifiTransferPIN = $0 })
    }

    private func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
