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

    /// The Mac has re-indexed the library since it was loaded (photos were added in Photos).
    var updateAvailable = false

    init(id: String) { self.id = id }

    /// Like the website: ask the Mac every minute whether the library changed, and offer to
    /// show the new photos rather than reloading under the viewer. Ends when cancelled.
    func watch(_ app: AppModel) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(DebugLaunch.pollSeconds ?? 60))
            guard !updateAvailable, let api = app.api, let loaded = detail?.rev else { continue }
            if let me = try? await api.libraries().first(where: { $0.id == id }), me.rev > loaded {
                updateAvailable = true
            }
        }
    }

    func load(_ app: AppModel) async {
        guard let api = app.api else { return }
        while !Task.isCancelled {
            do {
                switch try await api.library(id) {
                case .ready(let d):
                    apply(d)
                    updateAvailable = false
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
    @Namespace private var zoom

    // Pinch to change the number of columns, as in Photos: the grid scales with the fingers,
    // then settles on the next column step with the photo under the fingers kept in place.
    /// Chosen column count; nil = the default for the screen width.
    @State private var columns: Int?
    @State private var pinchScale: CGFloat = 1
    @State private var pinchAnchor: UnitPoint = .center
    @State private var position = ScrollPosition()
    @State private var scroll = ScrollGeometry?.none
    private static let spacing: CGFloat = 2

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columnCount),
                      spacing: Self.spacing) {
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
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, g in scroll = g }
        .scaleEffect(pinchScale, anchor: pinchAnchor)
        .clipped()
        .task(id: jump) {
            guard let jump else { return }
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(jump, anchor: .top)
        }
        // Swiping in the viewer moves the grid along underneath, so closing zooms back into
        // a tile that's on screen.
        .onChange(of: viewing) { _, id in
            // Not for the photo just tapped: its tile is on screen, and moving the grid as
            // the photo zooms out of it makes the opening jump.
            if let open, let id, id != assets[open.index].id { proxy.scrollTo(id, anchor: .center) }
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
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                pinchAnchor = v.startAnchor
                pinchScale = min(max(v.magnification, 0.5), 2.5)
            }
            .onEnded { v in settle(v.magnification, at: v.startAnchor) })
        .task {
            // Debug only: "0.6,0.5,0.5" = pinch in to 0.6 around the centre.
            guard let p = DebugLaunch.pinch else { return }
            try? await Task.sleep(for: .seconds(2))
            settle(p.scale, at: UnitPoint(x: p.x, y: p.y))
        }
        // Opens like Photos: the photo zooms out of its tile, and a swipe down sends it back.
        .fullScreenCover(item: $open) { _ in
            ViewerView(libraryID: libraryID, assets: assets, current: $viewing, downloads: downloads)
                .navigationTransition(.zoom(sourceID: viewing ?? "", in: zoom))
        }
    }

    /// Column steps that fit the width (tiles at least 40 points), like Photos' 1, 3, 5…
    private func steps(_ width: CGFloat) -> [Int] {
        [1, 3, 5, 7, 9, 11, 13].filter { width / CGFloat($0) >= 40 }
    }

    /// The chosen count, else the step nearest to tiles about 130 points wide (3 on iPhone).
    private var columnCount: Int {
        if let columns { return columns }
        let width = scroll?.containerSize.width ?? 400
        let ideal = width / 130
        return steps(width).min { abs(CGFloat($0) - ideal) < abs(CGFloat($1) - ideal) } ?? 3
    }

    /// Ends a pinch: one column step fewer (pinched out) or more (pinched in), keeping the
    /// photo that was under the fingers at the same place on screen.
    private func settle(_ magnification: CGFloat, at anchor: UnitPoint) {
        guard let g = scroll, !assets.isEmpty else { pinchScale = 1; return }
        let width = g.containerSize.width, sp = Self.spacing
        let all = steps(width), current = columnCount
        let i = all.firstIndex(of: current) ?? all.firstIndex { $0 > current } ?? all.count - 1
        var next = current
        if magnification > 1.15, i > 0 { next = all[i - 1] }
        if magnification < 0.87, i < all.count - 1 { next = all[i + 1] }

        // The photo under the fingers, and where on it they were.
        let finger = CGPoint(x: anchor.x * width, y: anchor.y * g.containerSize.height)
        let pitch = (width - sp * CGFloat(current - 1)) / CGFloat(current) + sp
        // contentOffset counts from the top of the screen, under the navigation bar; the
        // fingers' position counts from the top of the visible area, below it.
        let contentY = g.contentOffset.y + g.contentInsets.top + finger.y
        let row = max(0, floor(contentY / pitch))
        let fraction = (contentY - row * pitch) / pitch
        let column = min(CGFloat(current - 1), max(0, floor(finger.x / pitch)))
        let index = min(Int(row) * current + Int(column), assets.count - 1)

        pinchScale = 1
        guard next != current else { return }
        columns = next
        // Once laid out with the new columns, put that photo back under the fingers.
        let newPitch = (width - sp * CGFloat(next - 1)) / CGFloat(next) + sp
        let target = (CGFloat(index / next) + fraction) * newPitch - finger.y
        Task { @MainActor in
            await Task.yield()
            position.scrollTo(y: max(0, target))
        }
    }

    private var summary: String {
        let videos = assets.filter(\.isVideo).count
        let photos = assets.count - videos
        return [photos == 1 ? "1 Photo" : photos > 0 ? "\(photos.formatted()) Photos" : nil,
                videos == 1 ? "1 Video" : videos > 0 ? "\(videos.formatted()) Videos" : nil]
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

struct AlbumsGrid: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel
    @State private var debugHidden = DebugLaunch.hidden

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
                        HiddenAlbum(model: model)
                    } label: {
                        AlbumCell(title: "Hidden", count: model.hidden.count, cover: nil, symbol: "eye.slash")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationDestination(isPresented: $debugHidden) { HiddenAlbum(model: model) }
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

struct PeopleGrid: View {
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
