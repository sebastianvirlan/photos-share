import AppKit
import CoreLocation
import Photos

/// Spike: `PhotosShare --create-import manifest.json` creates photos in the System Photo Library
/// from all of a source photo's parts at once (original, Live video, RAW, edit recipe, edited
/// versions), which is the only way found that keeps Photos edits editable.
/// Driven by scripts/spike_create_import.py. Logs line by line, writes results.json, quits.
@MainActor
enum CreateSpike {
    struct Resource: Decodable {
        let type: String
        let path: String
        let optional: Bool?   // dropped on a retry if creating with it fails
    }

    struct Entry: Decodable {
        let source_uuid: String
        let name: String
        let kind: String
        let date: Double
        let lat: Double?
        let lon: Double?
        let favorite: Bool
        let resources: [Resource]
    }

    struct Outcome: Encodable {
        let source_uuid: String
        var created: String?
        var attempt: String?
        var errors: [String] = []
    }

    static var requested: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--create-import"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(_ manifest: URL) async {
        let dir = manifest.deletingLastPathComponent()
        let logURL = manifest.appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logFile = try? FileHandle(forWritingTo: logURL)
        func say(_ s: String) {
            logFile?.write(Data((s + "\n").utf8))
            try? logFile?.synchronize()
        }
        var outcomes: [Outcome] = []
        defer {
            if let data = try? JSONEncoder().encode(outcomes) {
                try? data.write(to: dir.appendingPathComponent("results.json"))
            }
            say("DONE")
            try? logFile?.close()
            exit(0)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let raw = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Entry].self, from: raw) else {
            return say("Couldn’t read \(manifest.path)")
        }
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            return say("Photos access wasn’t granted (System Settings → Privacy & Security → Photos).")
        }

        let albumName = "Import test \(Date().formatted(date: .omitted, time: .standard))"
        var albumID: String?
        try? await PHPhotoLibrary.shared().performChanges {
            albumID = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        let album = albumID.flatMap {
            PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
        }

        for e in entries {
            var outcome = Outcome(source_uuid: e.source_uuid)
            let all = e.resources
            let required = all.filter { $0.optional != true }
            let attempts = required.count == all.count
                ? [("all parts", all)]
                : [("all parts", all), ("without optional parts", required)]
            for (label, resources) in attempts {
                do {
                    outcome.created = try await create(e, resources, album: album)
                    outcome.attempt = label
                    say("✓ [\(e.kind)] \(e.name): created with \(label) (\(resources.map(\.type).joined(separator: " + ")))")
                    break
                } catch {
                    outcome.errors.append("\(label): \(error.localizedDescription)")
                    say("  ✗ [\(e.kind)] \(e.name), \(label): \(error.localizedDescription)")
                }
            }
            outcomes.append(outcome)
        }
        say("\nCreated \(outcomes.filter { $0.created != nil }.count) of \(entries.count), in the album “\(albumName)”.")
    }

    private static func create(_ e: Entry, _ resources: [Resource], album: PHAssetCollection?) async throws -> String {
        let types = try resources.map { r -> (PHAssetResourceType, URL) in
            guard let t = type(r.type) else { throw Failure("unknown part \(r.type)") }
            return (t, URL(fileURLWithPath: r.path))
        }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            for (i, (t, url)) in types.enumerated() {
                let o = PHAssetResourceCreationOptions()
                o.originalFilename = i == 0 ? e.name : url.lastPathComponent
                req.addResource(with: t, fileURL: url, options: o)
            }
            req.creationDate = Date(timeIntervalSince1970: e.date)
            if let lat = e.lat, let lon = e.lon { req.location = CLLocation(latitude: lat, longitude: lon) }
            req.isFavorite = e.favorite
            if let ph = req.placeholderForCreatedAsset {
                id = ph.localIdentifier
                if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray) }
            }
        }
        guard let id else { throw Failure("Photos didn’t return the new photo") }
        return id
    }

    private static func type(_ name: String) -> PHAssetResourceType? {
        switch name {
        case "photo": .photo
        case "video": .video
        case "pairedVideo": .pairedVideo
        case "alternatePhoto": .alternatePhoto
        case "adjustmentData": .adjustmentData
        case "fullSizePhoto": .fullSizePhoto
        case "fullSizeVideo": .fullSizeVideo
        case "fullSizePairedVideo": .fullSizePairedVideo
        case "adjustmentBasePhoto": .adjustmentBasePhoto
        case "adjustmentBasePairedVideo": .adjustmentBasePairedVideo
        default: nil
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
