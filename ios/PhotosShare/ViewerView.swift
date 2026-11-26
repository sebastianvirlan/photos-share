import AVKit
import SwiftUI
import UIKit

/// Full screen, swipe between photos, pinch or double-tap to zoom, tap to hide the controls.
struct ViewerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let libraryID: String
    let assets: [Asset]
    let downloads: Bool

    @State private var current: String?
    @State private var chrome = true
    @State private var playingLive = false
    @State private var saving = false
    @State private var message: String?
    @State private var sharing: [URL]?

    init(libraryID: String, assets: [Asset], start: Int, downloads: Bool) {
        self.libraryID = libraryID
        self.assets = assets
        self.downloads = downloads
        _current = State(initialValue: assets.indices.contains(start) ? assets[start].id : nil)
    }

    private var asset: Asset? { assets.first { $0.id == current } }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets) { a in
                    Page(libraryID: libraryID, asset: a, isCurrent: a.id == current,
                         playingLive: a.id == current && playingLive)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(a.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(chrome ? Color(.systemBackground) : .black)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chrome.toggle() } }
        .onChange(of: current) { playingLive = false }
        .overlay(alignment: .top) { if chrome { topBar } }
        .overlay(alignment: .bottom) { if chrome { bottomBar } }
        .overlay {
            if let message {
                Text(message).font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chrome)
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { ShareSheet(items: sharing).presentationDetents([.medium, .large]) }
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let d = asset?.date {
                    Text(d.formatted(date: .long, time: .omitted)).font(.headline)
                    Text(d.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if let place = asset?.place {
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).padding(10)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private var bottomBar: some View {
        HStack(spacing: 28) {
            Button { act(share: true) } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            if let a = asset, a.isLive {
                Text("LIVE").font(.caption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(playingLive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                                in: Capsule())
                    .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40) {
                    } onPressingChanged: { playingLive = $0 }
                    .accessibilityLabel("Hold to play the Live Photo")
            }
            Spacer()
            if asset?.isFavorite == true {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            Button { act(share: false) } label: {
                if saving { ProgressView() } else { Image(systemName: "square.and.arrow.down") }
            }
            .disabled(saving)
            .accessibilityLabel("Save to Photos")
        }
        .font(.title3)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
    }

    private func act(share: Bool) {
        guard let api = app.api, let a = asset, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                if share {
                    sharing = try await Saver.files(api, libraryID, a, downloads: downloads).map(\.url)
                } else {
                    try await Saver.saveToPhotos(api, libraryID, a, downloads: downloads)
                    flash(a.isVideo ? "Video saved to Photos" : "Saved to Photos")
                }
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation { message = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if message == text { message = nil } }
        }
    }
}

private struct Page: View {
    @Environment(AppModel.self) private var app
    let libraryID: String
    let asset: Asset
    let isCurrent: Bool
    let playingLive: Bool

    var body: some View {
        if let api = app.api {
            ZStack {
                if asset.isVideo {
                    VideoPage(api: api, libraryID: libraryID, asset: asset, isCurrent: isCurrent)
                } else {
                    ZoomablePhoto(api: api, libraryID: libraryID, asset: asset)
                    if playingLive {
                        LoopingPlayer(url: api.liveURL(libraryID, asset.u), cookie: api.cookie)
                            .aspectRatio(asset.aspect, contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

// MARK: - Photos

/// Shows the thumbnail at once, then the full-size image when it arrives.
private struct ZoomablePhoto: View {
    let api: API
    let libraryID: String
    let asset: Asset
    @State private var image: UIImage?

    var body: some View {
        ZoomView(image: image)
            .task(id: asset.id) {
                let thumb = api.thumbURL(libraryID, asset.u)
                image = ImageLoader.shared.cached(thumb, maxPixels: 360)
                if image == nil { image = await ImageLoader.shared.image(api, thumb, maxPixels: 640) }
                let scale = UIScreen.main.scale
                let px = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale
                if let full = await ImageLoader.shared.image(api, api.photoURL(libraryID, asset.u),
                                                             maxPixels: min(px * 2, 4096)) {
                    image = full
                }
            }
    }
}

/// UIScrollView does pinch-zoom, panning and bounce exactly like Photos; SwiftUI alone doesn't.
private struct ZoomView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomingScrollView { ZoomingScrollView() }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if view.imageView.image !== image { view.setImage(image) }
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: UIImage?) {
        let wasZoomed = zoomScale > minimumZoomScale
        imageView.image = image
        if !wasZoomed { layoutImage() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale { layoutImage() }
        centre()
    }

    private func layoutImage() {
        guard bounds.width > 0 else { return }
        zoomScale = 1
        imageView.frame = bounds
        contentSize = bounds.size
        let size = imageView.image?.size ?? bounds.size
        // Up to the photo's own pixels, and at least 3×, so small photos still zoom.
        let fit = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        minimumZoomScale = 1
        maximumZoomScale = max(3, 1 / max(fit, 0.0001) / UIScreen.main.scale * 2)
    }

    private func centre() {
        let off = CGPoint(x: max(0, (bounds.width - contentSize.width) / 2),
                          y: max(0, (bounds.height - contentSize.height) / 2))
        imageView.center = CGPoint(x: contentSize.width / 2 + off.x, y: contentSize.height / 2 + off.y)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

// MARK: - Video

private struct VideoPage: View {
    @Environment(AppModel.self) private var app
    let api: API
    let libraryID: String
    let asset: Asset
    let isCurrent: Bool
    @State private var player: AVPlayer?
    @State private var preparing = false
    @State private var failed = false

    var body: some View {
        ZStack {
            RemoteImage(url: api.thumbURL(libraryID, asset.u), maxPixels: 640, contentMode: .fit)
            if let player {
                VideoPlayer(player: player)
            } else if preparing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("The Mac is converting this video…").font(.footnote)
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if failed {
                Label("This video can’t be played", systemImage: "exclamationmark.triangle")
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: isCurrent) {
            guard isCurrent else { player?.pause(); return }
            if player == nil { await prepare() }
        }
    }

    private func prepare() async {
        // When the Mac converts videos, it does so on request: wait for it to finish.
        if app.info?.video == "convert" {
            preparing = true
            defer { preparing = false }
            while !Task.isCancelled {
                guard let state = try? await api.videoReady(libraryID, asset.u) else { failed = true; return }
                if state == "ready" { break }
                if state == "error" { failed = true; return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard !Task.isCancelled else { return }
        player = AVPlayer(playerItem: AVPlayerItem(asset: Self.remoteAsset(api.videoURL(libraryID, asset.u), api.cookie)))
    }

    static func remoteAsset(_ url: URL, _ cookie: HTTPCookie?) -> AVURLAsset {
        AVURLAsset(url: url, options: cookie.map { [AVURLAssetHTTPCookiesKey: [$0]] } ?? [:])
    }
}

/// Plays a Live Photo's motion while the LIVE badge is held.
private struct LoopingPlayer: UIViewRepresentable {
    let url: URL
    let cookie: HTTPCookie?

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        let player = AVPlayer(playerItem: AVPlayerItem(asset: VideoPage.remoteAsset(url, cookie)))
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        player.play()
        return v
    }

    func updateUIView(_ view: PlayerView, context: Context) {}

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
