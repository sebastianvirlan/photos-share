import SwiftUI

@main
struct PhotosShareApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if app.api != nil {
                    LibrariesView()
                } else {
                    ConnectView()
                }
            }
            .environment(app)
            .onChange(of: phase) { if phase == .background { app.hiddenUnlocked = false } }
            .task {
                guard let (address, password) = DebugLaunch.connect else { return }
                app.disconnect()
                if let (base, needs) = try? await app.probe(address) {
                    try? await app.connect(base: base, password: needs ? password : nil)
                }
            }
        }
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var password = ""
    @State private var needsPassword: URL?
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case address, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("name.ts.net or the link you were sent", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.go)
                        .onSubmit(go)
                        .onChange(of: address) { needsPassword = nil }
                } header: {
                    Text("Address")
                } footer: {
                    Text("The link shown on the Mac under Sharing. For a private (Tailscale) link, this iPhone needs the Tailscale app, signed in to the same account.")
                }

                if needsPassword != nil {
                    Section("Password") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(go)
                    }
                }

                if let notice = app.notice, error == nil {
                    Section { Label(notice, systemImage: "key.fill").foregroundStyle(.orange) }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                Section {
                    Button(action: go) {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text(needsPassword == nil ? "Connect" : "Sign In").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || address.isEmpty || (needsPassword != nil && password.isEmpty))
                }
            }
            .navigationTitle("Photos Share")
            .onAppear {
                if address.isEmpty, let last = app.lastAddress { address = last }
                focus = .address
            }
        }
    }

    private func go() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if let base = needsPassword {
                    try await app.connect(base: base, password: password)
                    password = ""
                } else {
                    let (base, needs) = try await app.probe(address)
                    if needs {
                        needsPassword = base
                        focus = .password
                    } else {
                        try await app.connect(base: base, password: nil)
                    }
                }
            } catch {
                self.error = Self.describe(error)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "Couldn’t find that address. For a private link, check Tailscale is on, on this iPhone."
            case .cannotConnectToHost, .timedOut, .networkConnectionLost:
                return "The Mac didn’t answer. Is it sharing, and awake?"
            case .notConnectedToInternet: return "This iPhone is offline."
            case .appTransportSecurityRequiresSecureConnection:
                return "This address needs https://, or a Tailscale (ts.net) name."
            default: return e.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
