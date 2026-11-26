import SwiftUI

/// The app once connected: Photos, Albums and People tabs for one shared library, like the
/// Photos app. With several libraries shared, the title is a menu to switch between them.
struct LibraryRoot: View {
    @Environment(AppModel.self) private var app
    @State private var libraries: [LibrarySummary] = []
    @State private var loaded = false
    @State private var error: String?
    @AppStorage("libraryID") private var libraryID = ""
    @State private var model: LibraryModel?
    @State private var tab: Page = Page(rawValue: DebugLaunch.tab ?? "") ?? .photos

    enum Page: String { case photos, albums, people }

    private var current: LibrarySummary? {
        libraries.first { $0.id == libraryID } ?? libraries.first
    }

    var body: some View {
        Group {
            if let error, libraries.isEmpty {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Can’t reach the Mac", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await loadLibraries() } }
                        Button("Disconnect", role: .destructive) { app.disconnect() }
                    }
                }
            } else if !loaded {
                ProgressView()
            } else if let model, let current {
                TabView(selection: $tab) {
                    Tab("Photos", systemImage: "photo.on.rectangle", value: Page.photos) {
                        screen(current, model) { PhotosTab(model: model) }
                    }
                    Tab("Albums", systemImage: "rectangle.stack", value: Page.albums) {
                        screen(current, model) { AlbumsGrid(model: model) }
                    }
                    Tab("People", systemImage: "person.2", value: Page.people) {
                        screen(current, model) { PeopleGrid(model: model) }
                    }
                }
            } else {
                NavigationStack {
                    ContentUnavailableView("Nothing shared", systemImage: "photo.on.rectangle",
                                           description: Text("The Mac isn’t sharing any libraries."))
                        .toolbar { ToolbarItem { Button("Disconnect") { app.disconnect() } } }
                }
            }
        }
        .task { await loadLibraries() }
        .onChange(of: current?.id) { open(current) }
    }

    /// One tab's screen: its own navigation, titled with the library, which is also the menu.
    private func screen<Content: View>(_ lib: LibrarySummary, _ model: LibraryModel,
                                       @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationStack {
            LibraryState(model: model, content: content)
                .navigationTitle(lib.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarTitleMenu {
                    if libraries.count > 1 {
                        Picker("Library", selection: $libraryID) {
                            ForEach(libraries) { l in
                                Text(l.name).tag(l.id)
                            }
                        }
                    }
                    Section(app.address ?? "") {
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { app.disconnect() }
                    }
                }
                .refreshable { await model.load(app) }
        }
    }

    private func loadLibraries() async {
        guard let api = app.api else { return }
        do {
            libraries = try await api.libraries()
            error = nil
        } catch APIError.needsPassword {
            app.signedOut()
        } catch {
            self.error = ConnectView.describe(error)
        }
        loaded = true
        if model == nil { open(current) }
    }

    private func open(_ lib: LibrarySummary?) {
        guard let lib, model?.id != lib.id else { return }
        let m = LibraryModel(id: lib.id)
        model = m
        Task { await m.load(app) }
    }
}

/// The library's content once it's open, or why it isn't yet.
private struct LibraryState<Content: View>: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .opening:
            VStack(spacing: 12) {
                ProgressView()
                Text("The Mac is opening this library…").foregroundStyle(.secondary)
                Text("Big libraries take a minute the first time.").font(.footnote).foregroundStyle(.tertiary)
            }
        case .unavailable:
            ContentUnavailableView("Library not available", systemImage: "externaldrive.badge.xmark",
                                   description: Text("Its drive may be unplugged from the Mac."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t open", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.load(app) } }
            }
        case .ready:
            content()
        }
    }
}
