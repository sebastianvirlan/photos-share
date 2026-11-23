import CoreLocation
import Foundation
import Photos

/// Creates photos in the System Photo Library from all their parts at once (original, Live
/// video, RAW, Photos' edit recipe, edited versions). Photos accepts its own edit recipe this
/// way, so edits arrive still editable: the only public route that does. Parts come from
/// `photos-import --parts`.
enum PhotoKitImport {
    struct Part: Codable {
        let type: String
        let path: String
        let optional: Bool?
    }

    struct Item: Codable {
        let source_uuid: String
        let name: String?
        let date: Double
        let lat: Double?
        let lon: Double?
        let favorite: Bool
        let hidden: Bool
        let albums: [String]
        let resources: [Part]
    }

    struct Manifest: Codable {
        let items: [Item]
        let problems: [ImportSummary.Problem]
    }

    /// Handed to `photos-import --finish`.
    struct Run: Codable {
        struct Created: Codable { let source_uuid: String; let created: String }
        var requested: Int
        var created: [Created] = []
        var failed: [ImportSummary.Problem] = []
        var cancelled = false
        /// Photos refused this many in a row and the import stopped (photos-import says why).
        var refused: Int? = nil
    }

    /// Stop once Photos has refused this many photos in a row (a full disk refuses everything).
    static let stopAfter = 5

    /// A run saved after every batch, so an import cut short (quit, crash) can still be
    /// checked and given its titles, captions and keywords later. Removed once finished.
    struct Journal: Codable, Identifiable {
        var id = UUID()
        let source: String
        let dest: String
        let started: Date
        var run: Run

        static var folder: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Photos Share/Interrupted Imports", isDirectory: true)
        }
        var file: URL { Self.folder.appendingPathComponent("\(id.uuidString).json") }
        var destName: String { URL(fileURLWithPath: dest).deletingPathExtension().lastPathComponent }

        func save() throws {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        }
        func remove() { try? FileManager.default.removeItem(at: file) }

        /// Imports that stopped before they were checked, oldest first.
        static func all() -> [Journal] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: $0)) }
                .sorted { $0.started < $1.started }
        }
    }

    static let batchSize = 10

    static func authorize() async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            throw Failure("Photos Share needs Full Access to Photos to keep edits (System Settings → Privacy & Security → Photos).")
        }
    }

    /// Existing albums by title (top level and in folders), creating any that are missing.
    static func albums(named titles: Set<String>) async throws -> [String: PHAssetCollection] {
        var found: [String: PHAssetCollection] = [:]
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { c, _, _ in
                if let t = c.localizedTitle, titles.contains(t), found[t] == nil { found[t] = c }
            }
        let missing = titles.subtracting(found.keys)
        guard !missing.isEmpty else { return found }
        var ids: [String: String] = [:]
        try await PHPhotoLibrary.shared().performChanges {
            for t in missing {
                ids[t] = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: t)
                    .placeholderForCreatedAssetCollection.localIdentifier
            }
        }
        let made = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: Array(ids.values), options: nil)
        made.enumerateObjects { c, _, _ in
            if let t = ids.first(where: { $0.value == c.localIdentifier })?.key { found[t] = c }
        }
        return found
    }

    /// Creates a batch in one change; if Photos refuses the batch, each photo on its own, and
    /// a photo it still refuses once more without its optional parts (the edited Live video).
    static func create(_ batch: [Item], albums: [String: PHAssetCollection], into run: inout Run) async {
        if let ids = try? await perform(batch.map { ($0, $0.resources) }, albums: albums) {
            for (item, id) in zip(batch, ids) { run.created.append(.init(source_uuid: item.source_uuid, created: id)) }
            return
        }
        for item in batch {
            let required = item.resources.filter { $0.optional != true }
            var lastError: Error?
            for parts in required.count == item.resources.count ? [item.resources] : [item.resources, required] {
                do {
                    let id = try await perform([(item, parts)], albums: albums)[0]
                    run.created.append(.init(source_uuid: item.source_uuid, created: id))
                    lastError = nil
                    break
                } catch {
                    lastError = error
                }
            }
            if let lastError {
                run.failed.append(.init(uuid: item.source_uuid, name: item.name,
                                        reason: "Photos refused it: \(lastError.localizedDescription)"))
            }
        }
    }

    private static func perform(_ work: [(Item, [Part])], albums: [String: PHAssetCollection]) async throws -> [String] {
        var ids: [String] = []
        try await PHPhotoLibrary.shared().performChanges {
            ids = []
            var byAlbum: [String: [PHObjectPlaceholder]] = [:]
            for (item, parts) in work {
                let req = PHAssetCreationRequest.forAsset()
                for (i, part) in parts.enumerated() {
                    guard let type = resourceType(part.type) else { continue }
                    let url = URL(fileURLWithPath: part.path)
                    let o = PHAssetResourceCreationOptions()
                    o.originalFilename = i == 0 ? (item.name ?? url.lastPathComponent) : url.lastPathComponent
                    req.addResource(with: type, fileURL: url, options: o)
                }
                req.creationDate = Date(timeIntervalSince1970: item.date)
                if let lat = item.lat, let lon = item.lon { req.location = CLLocation(latitude: lat, longitude: lon) }
                req.isFavorite = item.favorite
                req.isHidden = item.hidden
                if let ph = req.placeholderForCreatedAsset {
                    ids.append(ph.localIdentifier)
                    for a in item.albums { byAlbum[a, default: []].append(ph) }
                }
            }
            for (title, placeholders) in byAlbum {
                if let album = albums[title] {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
                }
            }
        }
        guard ids.count == work.count else { throw Failure("Photos didn’t return the new photos") }
        return ids
    }

    private static func resourceType(_ name: String) -> PHAssetResourceType? {
        switch name {
        case "photo": .photo
        case "video": .video
        case "pairedVideo": .pairedVideo
        case "alternatePhoto": .alternatePhoto
        case "adjustmentData": .adjustmentData
        case "fullSizePhoto": .fullSizePhoto
        case "fullSizeVideo": .fullSizeVideo
        case "fullSizePairedVideo": .fullSizePairedVideo
        default: nil
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
