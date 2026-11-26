import Foundation
import Photos

/// Fetches a photo or video from the share and saves it into this iPhone's Photos.
enum Saver {
    struct File { let url: URL; let kind: PHAssetResourceType }

    enum Failure: LocalizedError {
        case notAllowed, download(Int)
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Allow Photos Share to add to your photos in Settings, then try again."
            case .download(let code): "Couldn’t download it from the Mac (\(code))."
            }
        }
    }

    /// The files for `asset`. With downloads allowed on the Mac: the real file (as it looks,
    /// in its own format, so HEIC and HDR stay intact), plus a Live Photo's motion. Otherwise
    /// the same JPEG or video the viewer shows.
    static func files(_ api: API, _ lib: String, _ asset: Asset, downloads: Bool) async throws -> [File] {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let main: File
        if downloads {
            main = File(url: try await fetch(api, "/download/\(lib)/\(asset.u)", into: dir, fallback: "\(asset.u).\(asset.isVideo ? "mov" : "jpg")"),
                        kind: asset.isVideo ? .video : .photo)
        } else if asset.isVideo {
            main = File(url: try await fetch(api, "/video/\(lib)/\(asset.u)", into: dir, fallback: "\(asset.u).mov"), kind: .video)
        } else {
            main = File(url: try await fetch(api, "/photo/\(lib)/\(asset.u)", into: dir, fallback: "\(asset.u).jpg"), kind: .photo)
        }
        var out = [main]
        if downloads, asset.isLive, !asset.isVideo,
           let live = try? await fetch(api, "/live/\(lib)/\(asset.u)", into: dir, fallback: "\(asset.u).mov") {
            out.append(File(url: live, kind: .pairedVideo))
        }
        return out
    }

    static func saveToPhotos(_ api: API, _ lib: String, _ asset: Asset, downloads: Bool) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        let files = try await files(api, lib, asset, downloads: downloads)
        defer { try? FileManager.default.removeItem(at: files[0].url.deletingLastPathComponent()) }
        do {
            try await create(files)
        } catch {
            // Photos refuses a Live pair whose two halves don't match (e.g. an edited photo
            // with the original motion): keep the photo at least.
            guard files.count > 1 else { throw error }
            try await create([files[0]])
        }
    }

    private static func create(_ files: [File]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            for f in files {
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = f.url.lastPathComponent
                req.addResource(with: f.kind, fileURL: f.url, options: o)
            }
        }
    }

    private static func fetch(_ api: API, _ path: String, into dir: URL, fallback: String) async throws -> URL {
        let (tmp, resp) = try await API.session.download(for: api.request(path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.download(code) }
        var name = resp.suggestedFilename ?? fallback
        if name.isEmpty || !name.contains(".") { name = fallback }
        let dest = dir.appending(path: name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
