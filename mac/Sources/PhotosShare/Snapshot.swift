import AppKit
import SwiftUI

/// Developer aid: `PhotosShare --snapshot <folder>` renders the windows to PNGs with sample
/// data and exits. Used to review layout without clicking through the app.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let empty = CleanupModel()
        render(CleanupView(model: empty).frame(width: 900, height: 600), to: dir, name: "cleanup-empty")

        let chosen = CleanupModel()
        chosen.showForSnapshot(nil, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                               dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        render(CleanupView(model: chosen).frame(width: 900, height: 600), to: dir, name: "cleanup-chosen")

        let results = CleanupModel()
        results.showForSnapshot(sample, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                                dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        render(CleanupView(model: results).frame(width: 900, height: 640), to: dir, name: "cleanup-results")

        let imp = ImportModel()
        render(ImportView(model: imp).frame(width: 960, height: 640), to: dir, name: "import-empty")
        let loaded = ImportModel()
        loaded.showForSnapshot(importSample, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                               dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        render(ImportView(model: loaded).frame(width: 960, height: 640), to: dir, name: "import-loaded")
        var system = importSample
        system.dest_is_system = true
        let keeping = ImportModel()
        keeping.showForSnapshot(system, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                                dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        render(ImportView(model: keeping).frame(width: 960, height: 640), to: dir, name: "import-keeps-edits")

        // ShareView is an AppKit-backed grouped Form, which ImageRenderer can't draw.
        exit(0)
    }

    private static func render<V: View>(_ view: V, to dir: URL, name: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { print("could not render \(name)"); return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        print("wrote \(name).png")
    }

    private static let importSample: ImportPlan = {
        let items = (1...40).map { n in
            ImportItem(uuid: "I\(n)", name: "IMG_\(2000 + n).HEIC", date: "202\(n % 3 + 1)-0\(n % 9 + 1)-10T10:00:00+01:00",
                       thumb: nil, movie: n % 9 == 0, live: n % 4 == 0, favorite: n % 6 == 0, edited: n % 7 == 0,
                       hidden: false, albums: n % 5 == 0 ? ["Holiday"] : [], in_dest: n % 3 == 0)
        }
        return ImportPlan(source: "/Volumes/HDD/iPhone 13 Backup.photoslibrary", dest: "/Volumes/HDD/Trips.photoslibrary",
                          source_name: "iPhone 13 Backup", dest_name: "Trips", albums: ["Holiday", "Family"], items: items)
    }()

    private static let sample: CleanupReport = {
        func row(_ n: Int, reason: String? = nil, dest: Bool = true) -> CleanupRow {
            CleanupRow(uuid: "U\(n)", name: "img_\(1000 + n).heic", date: "2023-09-1\(n % 9)T10:00:00+01:00",
                       edited: n % 7 == 0, thumb: nil, dest: dest ? "D\(n)" : nil,
                       how: dest ? "fingerprint" : nil, dest_thumb: nil, reason: reason)
        }
        return CleanupReport(
            source: "/Volumes/HDD/iPhone 13 Backup.photoslibrary", dest: "/Volumes/HDD/Trips.photoslibrary",
            source_name: "iPhone 13 Backup", dest_name: "Trips", total: 60, all_verified: false,
            source_is_system: false, dest_is_system: false,
            matched: (1...41).map { row($0) }, edit_lost: (42...44).map { row($0) },
            missing: (45...58).map { row($0, dest: false) },
            needs_review: (59...60).map { row($0, reason: "The original file is missing from the destination library.") },
            outcome: nil)
    }()
}
