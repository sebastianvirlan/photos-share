import AppKit
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Spike: `PhotosShare --apply-edits manifest.json` puts edits from another library back onto
/// imported originals in the System Photo Library, through PhotoKit: the original Photos edit
/// recipe (from the .AAE) plus the image Photos rendered for it.
/// Driven by scripts/spike_apply_edits.py. Writes a log next to the manifest, then quits.
@MainActor
enum EditSpike {
    struct Entry: Decodable {
        let name: String
        let date: Double
        let format_id: String
        let format_version: String
        let data: String      // base64 adjustmentData from the .AAE
        let rendered: String  // the edited image Photos made in the source library
    }

    static var requested: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--apply-edits"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func run(_ manifest: URL) async {
        let logURL = manifest.appendingPathExtension("log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logFile = try? FileHandle(forWritingTo: logURL)
        func say(_ s: String) {  // written line by line, so the script can show progress
            logFile?.write(Data((s + "\n").utf8))
            try? logFile?.synchronize()
        }
        defer {
            say("DONE")
            try? logFile?.close()
            exit(0)
        }
        // A menu bar app's permission prompts can open behind other windows: come forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        guard let raw = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Entry].self, from: raw) else {
            return say("Couldn’t read \(manifest.path)")
        }
        say("Asking for access to Photos (current: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue))…")
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            return say("Photos access wasn’t granted (System Settings → Privacy & Security → Photos).")
        }

        let all = PHAsset.fetchAssets(with: .image, options: nil)
        var byName: [String: [PHAsset]] = [:]
        all.enumerateObjects { a, _, _ in
            for r in PHAssetResource.assetResources(for: a) where r.type == .photo {
                byName[r.originalFilename.lowercased(), default: []].append(a)
            }
        }

        say("Read \(all.count) photos in the System Photo Library.")
        for e in entries {
            let sameName = byName[e.name.lowercased()] ?? []
            let candidates = sameName.filter { a in
                guard let d = a.creationDate?.timeIntervalSince1970 else { return false }
                return abs(d - e.date) < 2
            }
            if candidates.isEmpty {
                let dates = sameName.map { "\(Int(($0.creationDate?.timeIntervalSince1970 ?? 0) - e.date))s off" }
                say("✗ \(e.name): not found with the same date (\(sameName.isEmpty ? "no photo with that name" : "same name, dates " + dates.joined(separator: ", ")))")
                continue
            }
            for a in candidates {
                say("… \(e.name): \(a.pixelWidth)×\(a.pixelHeight)\(isEdited(a) ? ", has an edit already (will be replaced)" : ""), edited image: \(describe(URL(fileURLWithPath: e.rendered)))")
                NSApp.activate(ignoringOtherApps: true)
                var saved = false
                for attempt in Attempt.allCases where !saved {
                    do {
                        try await apply(e, to: a, attempt)
                        say("✓ \(e.name): saved with \(attempt.label)")
                        saved = true
                    } catch {
                        say("  ✗ \(attempt.label): \(error.localizedDescription)")
                    }
                }
            }
        }
        say("\nNow look at these photos in Photos: do they look edited, is Image → Revert to Original there, and does Edit show your adjustments?")
    }

    private static func isEdited(_ a: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: a).contains { $0.type == .adjustmentData || $0.type == .fullSizePhoto }
    }

    enum Attempt: CaseIterable {
        case appleJPEG, appleHEIC, ownJPEG
        var label: String {
            switch self {
            case .appleJPEG: "Apple’s edit format + clean JPEG"
            case .appleHEIC: "Apple’s edit format + HEIC"
            case .ownJPEG: "our own edit format + clean JPEG (reversible only, not re-editable)"
            }
        }
    }

    private static func apply(_ e: Entry, to asset: PHAsset, _ attempt: Attempt) async throws {
        guard let data = Data(base64Encoded: e.data) else { throw Failure("bad recipe data") }
        let input = try await editingInput(asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = attempt == .ownJPEG
            ? PHAdjustmentData(formatIdentifier: "com.photosshare.restored-edit", formatVersion: "1",
                               data: Data(e.format_id.utf8) + data)
            : PHAdjustmentData(formatIdentifier: e.format_id, formatVersion: e.format_version, data: data)
        let src = URL(fileURLWithPath: e.rendered)
        if attempt == .appleHEIC {
            try writeClean(from: src, to: try output.renderedContentURL(for: .heic), type: .heic)
        } else {
            try writeClean(from: src, to: output.renderedContentURL, type: .jpeg)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    private static func describe(_ url: URL) -> String {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return "unreadable \(url.lastPathComponent)" }
        return "\(url.lastPathComponent) \(p[kCGImagePropertyPixelWidth] ?? "?")×\(p[kCGImagePropertyPixelHeight] ?? "?") orientation \(p[kCGImagePropertyOrientation] ?? 1)"
    }

    private static func editingInput(_ asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { cont in
            let opts = PHContentEditingInputRequestOptions()
            opts.isNetworkAccessAllowed = false
            opts.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: opts) { input, info in
                if let input { cont.resume(returning: input) }
                else { cont.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? Failure("Photos gave no editing input")) }
            }
        }
    }

    /// Redraws the image upright with no metadata, at full size.
    private static func writeClean(from src: URL, to dst: URL, type: UTType) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failure("couldn’t read the edited image \(src.lastPathComponent)") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure("couldn’t write the edited image") }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
