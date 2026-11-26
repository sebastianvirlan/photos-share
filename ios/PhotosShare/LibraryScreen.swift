import SwiftUI

/// One shared library, pushed from the libraries list: Photos, Albums and People tabs. On
/// Photos the top line is the back button, Years / Months / All Photos, and the filter.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    let summary: LibrarySummary
    @State private var model: LibraryModel
    @State private var tab: Page = Page(rawValue: DebugLaunch.tab ?? "") ?? .photos
    @State private var zoom: PhotosTab.Zoom = PhotosTab.Zoom(rawValue: DebugLaunch.zoom ?? "") ?? .all

    enum Page: String { case photos, albums, people }

    init(summary: LibrarySummary) {
        self.summary = summary
        _model = State(initialValue: LibraryModel(id: summary.id))
    }

    private var showsPhotoControls: Bool {
        if case .ready = model.state { return tab == .photos && !model.photos.isEmpty }
        return false
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Photos", systemImage: "photo.on.rectangle", value: Page.photos) {
                LibraryState(model: model) { PhotosTab(model: model, zoom: $zoom) }
            }
            Tab("Albums", systemImage: "rectangle.stack", value: Page.albums) {
                LibraryState(model: model) { AlbumsGrid(model: model) }
            }
            Tab("People", systemImage: "person.2", value: Page.people) {
                LibraryState(model: model) { PeopleGrid(model: model) }
            }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsPhotoControls {
                ToolbarItem(placement: .principal) {
                    Picker("Group by", selection: $zoom) {
                        ForEach(PhotosTab.Zoom.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $model.filter) {
                            ForEach(LibraryModel.Filter.allCases, id: \.self) {
                                Label($0.rawValue, systemImage: $0.symbol)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: model.filter == .all
                              ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .task { await model.load(app) }
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
                .refreshable { await model.load(app) }
        }
    }
}
