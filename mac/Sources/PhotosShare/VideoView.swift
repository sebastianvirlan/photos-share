import AVKit
import SwiftUI

/// A video with the standard macOS controls. Uses AVPlayerView directly: SwiftUI's own
/// VideoPlayer crashed in this app (it couldn't find AVPlayerView when built with SwiftPM).
struct VideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()  // stop the sound when the preview closes or moves on
        view.player = nil
    }
}
