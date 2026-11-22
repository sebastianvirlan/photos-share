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
            let candidates = (byName[e.name.lowercased()] ?? []).filter { a in
                guard let d = a.creationDate?.timeIntervalSince1970 else { return false }
                return abs(d - e.date) < 2 && !isEdited(a)
            }
            if candidates.isEmpty {
                say("✗ \(e.name): no unedited copy with the same date in the System Photo Library")
                continue
            }
            for a in candidates {
                do {
                    say("… \(e.name): saving the edit (macOS may ask you to allow it)")
                    NSApp.activate(ignoringOtherApps: true)
                    try await apply(e, to: a)
                    say("✓ \(e.name): edit saved (\(e.format_id) \(e.format_version))")
                } catch {
                    say("✗ \(e.name): \(error.localizedDescription)")
                }
            }
        }
        say("\nNow look at these photos in Photos: do they look edited, is Image → Revert to Original there, and does Edit show your adjustments?")
    }

    private static func isEdited(_ a: PHAsset) -> Bool {
        PHAssetResource.assetResources(for: a).contains { $0.type == .adjustmentData || $0.type == .fullSizePhoto }
    }

    private static func apply(_ e: Entry, to asset: PHAsset) async throws {
        guard let data = Data(base64Encoded: e.data) else { throw Failure("bad recipe data") }
        let input = try await editingInput(asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: e.format_id,
                                                 formatVersion: e.format_version, data: data)
        try writeJPEG(from: URL(fileURLWithPath: e.rendered), to: output.renderedContentURL)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
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

    private static func writeJPEG(from src: URL, to dst: URL) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure("couldn’t read the edited image \(src.lastPathComponent)") }
        CGImageDestinationAddImageFromSource(dest, source, 0,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure("couldn’t write the edited image") }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }
}
