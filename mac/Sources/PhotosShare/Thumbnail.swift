import AppKit
import ImageIO
import SwiftUI

/// Small, cached previews loaded from the JPEGs Photos already keeps inside each library.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(at path: String, maxPixels: Int) async -> NSImage? {
        let key = "\(maxPixels):\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
                return nil
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,  // respect orientation
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

struct Thumbnail: View {
    let path: String?
    var maxPixels = 320
    var fill = true
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else if failed || path == nil {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: path) {
            guard let path else { return }
            image = await ThumbnailCache.shared.image(at: path, maxPixels: maxPixels)
            failed = image == nil
        }
    }
}
