import AppKit
import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel
    @State private var password = ""
    @State private var passwordSaved = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent {
                    Button("Choose…") { choose() }.disabled(model.isActive)
                } label: {
                    if let path = model.path {
                        Label(URL(fileURLWithPath: path).lastPathComponent,
                              systemImage: path.hasSuffix(".photoslibrary") ? "photo.stack" : "folder")
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Choose a Photos library, or a folder that contains several.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Who can see it") {
                Picker("Access", selection: $model.mode) {
                    ForEach(AccessMode.allCases) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title)
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }.tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(model.isActive)
            }

            Section("Options") {
                Toggle("Require a password", isOn: $model.requirePassword)
                    .disabled(model.isActive || model.mode == .funnel)
                Toggle(isOn: $model.hidden) {
                    Text("Include hidden photos")
                    Text("Shown only under “Hidden”, as in Photos.")
                }
                Toggle("Show screenshots", isOn: $model.screenshots)
                Toggle("Allow downloading originals", isOn: $model.downloads)
                Toggle("Convert videos for any browser", isOn: $model.convertVideo)
                Toggle("Keep this Mac awake while sharing", isOn: $model.keepAwake)
            }
            .disabled(model.isActive)

            if model.needsPassword {
                Section("Password for viewers") {
                    HStack {
                        SecureField(model.hasPassword ? "Saved. Type to change it" : "At least 8 characters",
                                    text: $password)
                        Button("Save") {
                            model.savePassword(password)
                            password = ""
                            passwordSaved = true
                        }
                        .disabled(password.count < 8)
                    }
                    Text(passwordSaved ? "Saved in your Keychain. Changing it signs viewers out."
                         : "Viewers enter it once per device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                status
                HStack {
                    if model.isActive {
                        Button("Stop Sharing", role: .destructive) { model.stop() }
                    } else {
                        Button("Start Sharing") { model.start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.path == nil || (model.needsPassword && !model.hasPassword))
                    }
                    Spacer()
                    if model.isRunning {
                        Button("Copy Link") { model.copyLink() }
                        Button("Open") { model.openLink() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .stopped:
            Label("Not sharing", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            HStack { ProgressView().controlSize(.small); Text("Starting…") }
        case .running(let url):
            VStack(alignment: .leading, spacing: 4) {
                Label("Sharing", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                Text(url).font(.body.monospaced()).textSelection(.enabled)
                if model.mode == .funnel {
                    Text("Public link: anyone who has it reaches the password page.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true      // a .photoslibrary is a package, shown as a file
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Photos library, or a folder that contains several."
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isLibrary = url.pathExtension == "photoslibrary"
        let hasLibraries = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .contains { $0.hasSuffix(".photoslibrary") } ?? false
        guard isLibrary || hasLibraries else {
            let alert = NSAlert()
            alert.messageText = "Not a Photos library"
            alert.informativeText = "“\(url.lastPathComponent)” isn’t a .photoslibrary and doesn’t contain any."
            alert.runModal()
            return
        }
        model.path = url.path
    }
}
