import ImageIO
import SwiftUI
import UIKit

/// Loads images from the share: decoded at the size they're shown at, kept in memory, and on
/// disk through the URL cache (the server marks thumbnails and photos cacheable for a week).
actor ImageLoader {
    static let shared = ImageLoader()

    // NSCache is thread-safe, so reading it without hopping onto the actor is fine.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    init() { memory.totalCostLimit = 200 << 20 }

    nonisolated func cached(_ url: URL, maxPixels: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixels))
    }

    func image(_ api: API, _ url: URL, maxPixels: CGFloat) async -> UIImage? {
        let key = Self.key(url, maxPixels)
        if let hit = memory.object(forKey: key) { return hit }
        if let task = running[key as String] { return await task.value }
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let got = try? await API.session.data(for: api.request(url: url)),
                  (got.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.decode(got.0, maxPixels: maxPixels)
        }
        running[key as String] = task
        let image = await task.value
        running[key as String] = nil
        if let image {
            memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }

    private static func key(_ url: URL, _ px: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(px))" as NSString }

    /// Decodes straight to the size needed, so a grid of thumbnails doesn't hold full bitmaps.
    static func decode(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// An image from the share, filling its frame. Shows a grey placeholder until loaded.
struct RemoteImage: View {
    @Environment(AppModel.self) private var app
    let url: URL
    var maxPixels: CGFloat = 400
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(Color(.secondarySystemFill))
            }
        }
        .task(id: url) {
            if let hit = ImageLoader.shared.cached(url, maxPixels: maxPixels) { image = hit; return }
            guard let api = app.api else { return }
            image = await ImageLoader.shared.image(api, url, maxPixels: maxPixels)
        }
    }
}

/// A square tile with the image cropped to fill it.
struct SquareImage: View {
    let url: URL
    var maxPixels: CGFloat = 400

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteImage(url: url, maxPixels: maxPixels) }
            .clipped()
    }
}

/// A person's face cut out of one of their photos, as the website does it.
struct FaceAvatar: View {
    let api: API
    let libraryID: String
    let person: Person
    let asset: Asset?

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.width
            if let f = person.face, let a = asset, a.w > 0, a.h > 0 {
                let long = CGFloat(max(a.w, a.h))
                let side = max(f.s * 1.7, 0.02) * long          // face plus a margin, in photo pixels
                let w = CGFloat(a.w) / side * d, h = CGFloat(a.h) / side * d
                let zoomed = side / long * 640 < 140           // the thumbnail would be too blurry
                RemoteImage(url: zoomed ? api.photoURL(libraryID, a.u) : api.thumbURL(libraryID, a.u),
                            maxPixels: zoomed ? 2048 : 640)
                    .frame(width: w, height: h)
                    .offset(x: d / 2 - f.x * w, y: d / 2 - f.y * h)
                    .frame(width: d, height: d, alignment: .topLeading)
            } else {
                Text(person.name.prefix(1))
                    .font(.system(size: d * 0.4, weight: .semibold))
                    .frame(width: d, height: d)
                    .background(Color(.secondarySystemFill))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(Circle())
    }
}
