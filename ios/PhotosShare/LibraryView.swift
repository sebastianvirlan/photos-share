import SwiftUI

@MainActor @Observable
final class LibraryModel {
    enum State { case loading, opening, ready, unavailable, failed(String) }

    let id: String
    var state: State = .loading
    var detail: LibraryDetail?
    /// Oldest first, as the grid shows them (newest at the bottom, like Photos).
    var photos: [Asset] = []
    var hidden: [Asset] = []
    var byUUID: [String: Asset] = [:]
    /// `photos` by month and by year, oldest first.
    var months: [MonthGroup] = []
    var years: [YearGroup] = []

    init(id: String) { self.id = id }

    func load(_ app: AppModel) async {
        guard let api = app.api else { return }
        while !Task.isCancelled {
            do {
                switch try await api.library(id) {
                case .ready(let d):
                    apply(d)
                    if let f = DebugLaunch.filter.flatMap(Filter.init(rawValue:)) { filter = f }
                    state = .ready
                    return
                case .opening:
                    state = .opening      // the Mac is reading the library: ask again shortly
                case .unavailable:
                    state = .unavailable
                    return
                case .failed(let m):
                    state = .failed(m)
                    return
                }
            } catch APIError.needsPassword {
                app.signedOut()
                return
            } catch {
                if detail == nil { state = .failed(ConnectView.describe(error)) }
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    private func apply(_ d: LibraryDetail) {
        detail = d
        let all = d.assets.reversed()   // the server sends newest first
        photos = all.filter { !$0.isHidden }
        hidden = all.filter(\.isHidden)
        byUUID = Dictionary(d.assets.map { ($0.u, $0) }, uniquingKeysWith: { a, _ in a })
        regroup()
    }

    enum Filter: String, CaseIterable {
        case all = "All Items", favorites = "Favourites", photos = "Photos", videos = "Videos", live = "Live Photos"
        var symbol: String {
            switch self {
            case .all: "photo.on.rectangle"
            case .favorites: "heart"
            case .photos: "photo"
            case .videos: "video"
            case .live: "livephoto"
            }
        }
        func keeps(_ a: Asset) -> Bool {
            switch self {
            case .all: true
            case .favorites: a.isFavorite
            case .photos: !a.isVideo
            case .videos: a.isVideo
            case .live: a.isLive && !a.isVideo
            }
        }
    }

    /// What the Photos tab shows (Years, Months and All Photos alike).
    var filter: Filter = .all { didSet { if filter != oldValue { regroup() } } }
    /// `photos` after the filter.
    var shown: [Asset] = []

    private func regroup() {
        shown = filter == .all ? photos : photos.filter(filter.keeps)
        months = MonthGroup.group(shown)
        years = Dictionary(grouping: months, by: \.year).map { YearGroup(year: $0.key, months: $0.value) }
            .sorted { $0.year < $1.year }
    }

    func assets(of album: Album) -> [Asset] { album.uuids.compactMap { byUUID[$0] } }

    func assets(of person: Person) -> [Asset] {
        guard let i = detail?.people.firstIndex(of: person) else { return [] }
        return photos.filter { $0.p?.contains(i) ?? false }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    let summary: LibrarySummary
    @State private var model: LibraryModel
    @State private var tab: Tab = .photos
    @State private var zoom: PhotosTab.Zoom = PhotosTab.Zoom(rawValue: DebugLaunch.zoom ?? "") ?? .all

    enum Tab: String, CaseIterable { case photos = "Photos", albums = "Albums", people = "People" }

    init(summary: LibrarySummary) {
        self.summary = summary
        _model = State(initialValue: LibraryModel(id: summary.id))
        _tab = State(initialValue: DebugLaunch.tab.flatMap { t in Tab.allCases.first { $0.rawValue.lowercased() == t } } ?? .photos)
    }

    var body: some View {
        content
            .navigationTitle(summary.name)   // not shown; names the screen for the back button's menu
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
            .toolbar {
                // Only the back button and, on Photos, the Years / Months / All Photos switch.
                ToolbarItem(placement: .principal) {
                    if case .ready = model.state, tab == .photos, !model.photos.isEmpty {
                        GlassSwitcher(options: PhotosTab.Zoom.allCases.map { ($0, $0.title) }, selection: $zoom)
                    } else {
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                .noToolbarGlass()
                if case .ready = model.state, tab == .photos, !model.photos.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Show", selection: $model.filter) {
                                ForEach(LibraryModel.Filter.allCases, id: \.self) {
                                    Label($0.rawValue, systemImage: $0.symbol)
                                }
                            }
                        } label: {
                            Image(systemName: model.filter == .all
                                  ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityLabel("Filter")
                    }
                }
                if case .ready = model.state {
                    ToolbarItem(placement: .bottomBar) {
                        GlassSwitcher(options: Tab.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                    }
                    .noToolbarGlass()
                }
            }
            .task { await model.load(app) }
            .refreshable { await model.load(app) }
    }

    @ViewBuilder private var content: some View {
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
            switch tab {
            case .photos:
                PhotosTab(model: model, zoom: $zoom)
            case .albums:
                AlbumsGrid(model: model)
            case .people:
                PeopleGrid(model: model)
            }
        }
    }
}

// MARK: - Photo grid

struct PhotoGrid: View {
    @Environment(AppModel.self) private var app
    let libraryID: String
    let assets: [Asset]
    let downloads: Bool
    /// An item to bring into view (the first of the month picked in Months).
    var jump: String? = nil
    @State private var open: Opened?
    /// The item shown in the viewer, kept in step as you swipe there.
    @State private var viewing: String?
    @State private var columns = 3
    @Namespace private var zoom

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { i, a in
                    Button { viewing = a.id; open = Opened(index: i) } label: {
                        Tile(libraryID: libraryID, asset: a)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: a.id, in: zoom)
                }
            }
            if !assets.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 16)
            }
        }
        .defaultScrollAnchor(.bottom)      // newest at the bottom, like Photos
        .noEdgeFrosting()
        .task(id: jump) {
            guard let jump else { return }
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(jump, anchor: .top)
        }
        // Swiping in the viewer moves the grid along underneath, so closing zooms back into
        // a tile that's on screen.
        .onChange(of: viewing) { _, id in
            if open != nil, let id { proxy.scrollTo(id, anchor: .center) }
        }
        }
        .task {
            let i = assets.count - 1 - (DebugLaunch.openItem ?? -1)
            if DebugLaunch.openItem != nil, open == nil, assets.indices.contains(i) {
                try? await Task.sleep(for: .seconds(1))
                viewing = assets[i].id
                open = Opened(index: i)
            }
        }
        .overlay {
            if assets.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "photo")
            }
        }
        .simultaneousGesture(MagnifyGesture().onEnded { v in
            let next = v.magnification > 1 ? columns - 1 : columns + 1
            withAnimation { columns = min(max(next, 1), 7) }
        })
        // Opens like Photos: the photo zooms out of its tile, and a swipe down sends it back.
        .fullScreenCover(item: $open) { _ in
            ViewerView(libraryID: libraryID, assets: assets, current: $viewing, downloads: downloads)
                .navigationTransition(.zoom(sourceID: viewing ?? "", in: zoom))
        }
    }

    private var summary: String {
        let videos = assets.filter(\.isVideo).count
        let photos = assets.count - videos
        return [photos > 0 ? "\(photos.formatted()) Photos" : nil, videos > 0 ? "\(videos.formatted()) Videos" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private struct Opened: Identifiable { let index: Int; var id: Int { index } }
}

private struct Tile: View {
    @Environment(AppModel.self) private var app
    let libraryID: String
    let asset: Asset

    var body: some View {
        if let api = app.api {
            SquareImage(url: api.thumbURL(libraryID, asset.u), maxPixels: 360)
                .overlay(alignment: .bottomLeading) {
                    if asset.isFavorite {
                        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.white)
                            .shadow(radius: 2).padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if asset.isVideo {
                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white)
                            .shadow(radius: 2).padding(5)
                    }
                }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Albums and people

private struct AlbumsGrid: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel

    var body: some View {
        let albums = model.detail?.albums ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink {
                        PhotoGrid(libraryID: model.id, assets: model.assets(of: album),
                                  downloads: model.detail?.downloads ?? false)
                            .navigationTitle(album.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        AlbumCell(title: album.title, count: album.uuids.count,
                                  cover: album.cover.map { app.api?.thumbURL(model.id, $0) } ?? nil)
                    }
                    .buttonStyle(.plain)
                }
                if !model.hidden.isEmpty {
                    NavigationLink {
                        PhotoGrid(libraryID: model.id, assets: model.hidden,
                                  downloads: model.detail?.downloads ?? false)
                            .navigationTitle("Hidden")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        AlbumCell(title: "Hidden", count: model.hidden.count, cover: nil, symbol: "eye.slash")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if albums.isEmpty && model.hidden.isEmpty {
                ContentUnavailableView("No albums", systemImage: "rectangle.stack")
            }
        }
    }
}

private struct AlbumCell: View {
    let title: String
    let count: Int
    let cover: URL?
    var symbol = "photo.on.rectangle"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let cover {
                    SquareImage(url: cover, maxPixels: 500)
                } else {
                    Color(.secondarySystemFill).aspectRatio(1, contentMode: .fit)
                        .overlay { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title).font(.subheadline).lineLimit(1)
            Text(count.formatted()).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PeopleGrid: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel

    var body: some View {
        let people = model.detail?.people.filter { $0.count > 0 } ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 20) {
                ForEach(people) { person in
                    NavigationLink {
                        PhotoGrid(libraryID: model.id, assets: model.assets(of: person),
                                  downloads: model.detail?.downloads ?? false)
                            .navigationTitle(person.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(spacing: 6) {
                            if let api = app.api {
                                FaceAvatar(api: api, libraryID: model.id, person: person,
                                           asset: person.face.flatMap { model.byUUID[$0.u] })
                            }
                            Text(person.name).font(.subheadline).lineLimit(1)
                            Text(person.count.formatted()).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView("No people", systemImage: "person.2",
                                       description: Text("Name people in Photos on the Mac to see them here."))
            }
        }
    }
}

extension ToolbarContent {
    /// iOS 26 puts toolbar items on a shared glass capsule; a segmented control already has
    /// its own, and the two together look doubled.
    @ToolbarContentBuilder func noToolbarGlass() -> some ToolbarContent {
        if #available(iOS 26, *) { self.sharedBackgroundVisibility(.hidden) } else { self }
    }
}

extension View {
    /// iOS 26 frosts content scrolled under the top and bottom bars; photos should stay clear.
    @ViewBuilder func noEdgeFrosting() -> some View {
        if #available(iOS 26, *) { self.scrollEdgeEffectHidden(true, for: [.top, .bottom]) } else { self }
    }
}
