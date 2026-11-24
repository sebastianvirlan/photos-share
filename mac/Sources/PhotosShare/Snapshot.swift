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
        let comparing = CleanupModel()
        comparing.prepare(source: chosen.source, dest: chosen.dest)
        comparing.showProgressForSnapshot(.init(phase: "checking", done: 4_210, total: 11_873))
        render(CleanupView(model: comparing).frame(width: 900, height: 600), to: dir, name: "cleanup-comparing")

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
        let busy = ImportModel()
        busy.showForSnapshot(system, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                             dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        busy.showProgressForSnapshot(done: 30, total: 120)
        render(ImportView(model: busy).frame(width: 960, height: 640), to: dir, name: "import-progress")
        let after = ImportModel()
        after.showForSnapshot(system, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                              dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        let newOnes = system.items.filter { !$0.in_dest }.map(\.uuid)
        after.showResultForSnapshot(ImportSummary(
            imported: 10, requested: 12,
            failed: [.init(uuid: "x", name: "IMG_0042.HEIC", reason: "Photos refused it: unsupported file")],
            skipped_edited: [], imported_uuids: Array(newOnes.prefix(10))), requested: Set(newOnes.prefix(12)))
        render(ImportView(model: after).frame(width: 960, height: 640), to: dir, name: "import-result")
        // Stopped because the disk filled up, with an earlier import left unfinished.
        let stopped = ImportModel()
        stopped.showForSnapshot(system, source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                                dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        var cut = PhotoKitImport.Run(requested: 40)
        cut.created = newOnes.prefix(7).map { .init(source_uuid: $0, created: "X/L0/001") }
        stopped.showInterruptedForSnapshot([PhotoKitImport.Journal(
            source: "/Volumes/HDD/iPhone 13 Backup.photoslibrary", dest: "/Volumes/HDD/Trips.photoslibrary",
            started: Date(timeIntervalSince1970: 1_763_900_000), run: cut)])
        stopped.showResultForSnapshot(ImportSummary(
            imported: 20, requested: 25,
            failed: (1...5).map { .init(uuid: "f\($0)", name: "IMG_00\($0).HEIC", reason: "Photos refused it") },
            skipped_edited: [], imported_uuids: Array(newOnes.prefix(5)),
            stopped: "“HDD” is full (0.2 GB free), so Photos refused the last 5 photos. Free up space, then select the ones not imported and try again."),
            requested: Set(newOnes))
        render(ImportView(model: stopped).frame(width: 960, height: 640), to: dir, name: "import-stopped")
        render(PhotoPreview(model: keeping, uuid: system.items[0].uuid).frame(width: 1000, height: 700),
               to: dir, name: "import-preview")
        // A video in the preview (this crashed once inside SwiftUI's VideoPlayer).
        var withVideo = system
        withVideo.items[8].original = "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/BentoGalleryIntroduction.mov"
        let videoModel = ImportModel()
        videoModel.showForSnapshot(withVideo, source: nil, dest: nil)
        videoModel.onlyNew = false
        render(PhotoPreview(model: videoModel, uuid: withVideo.items[8].uuid).frame(width: 1000, height: 700),
               to: dir, name: "import-preview-video")

        let dup = DuplicatesModel()
        render(DuplicatesView(model: dup).frame(width: 960, height: 640), to: dir, name: "duplicates-empty")
        let dupLoaded = DuplicatesModel()
        dupLoaded.showForSnapshot(dupSample, library: URL(fileURLWithPath: "/Volumes/HDD/Seb&Mariana.photoslibrary"), system: false)
        render(DuplicatesView(model: dupLoaded).frame(width: 1000, height: 700), to: dir, name: "duplicates-results")
        // The list scrolls (which ImageRenderer can't draw): the tiles on their own.
        render(VStack(alignment: .leading, spacing: 16) {
            ForEach(dupSample) { g in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(g.copies) { c in
                        CopyTile(copy: c, keep: c.uuid == g.keep, removing: c.uuid != g.keep, exact: g.exact, size: 150)
                    }
                }
            }
        }.padding(20).frame(width: 700), to: dir, name: "duplicates-tiles")

        let badged = ImportItem(uuid: "B", name: "IMG_1.HEIC", date: "2025-01-01T10:00:00", thumb: nil, movie: false,
                                live: true, favorite: true, edited: true, hidden: true, albums: [], in_dest: true)
        render(HStack { ImportTile(item: badged, selected: true, destName: "Trips").frame(width: 160) }
               .padding(10).background(Color.gray), to: dir, name: "badges")

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

    private static let dupSample: [DupGroup] = {
        func c(_ u: String, _ name: String, w: Int = 4032, h: Int = 3024, size: Int = 2_400_000, fav: Bool = false,
               albums: [String] = [], dist: Int = 0) -> DupCopy {
            DupCopy(uuid: u, name: name, date: "2025-07-20T14:03:00", added: "2025-07-21T09:00:00", thumb: nil,
                    original: nil, width: w, height: h, size: size, movie: false, live: false, edited: false,
                    favorite: fav, hidden: false, albums: albums, keywords: [], title: nil, description: nil,
                    has_location: true, distance: dist)
        }
        return [
            DupGroup(kind: "exact", keep: "a1", copies: [c("a1", "IMG_3621.HEIC", fav: true, albums: ["Holiday"]), c("a2", "IMG_3621.HEIC")]),
            DupGroup(kind: "exact", keep: "b1", copies: [c("b1", "IMG_4410.HEIC"), c("b2", "IMG_4410.HEIC"), c("b3", "IMG_4410.HEIC")]),
            DupGroup(kind: "near", keep: "n1", copies: [c("n1", "IMG_5120.HEIC"), c("n2", "IMG-20250720-WA0003.jpg", w: 1600, h: 1200, size: 310_000, dist: 3)]),
        ]
    }()

    static let importSample: ImportPlan = {
        let items = (1...40).map { n in
            ImportItem(uuid: "I\(n)", name: "IMG_\(2000 + n).HEIC", date: "202\(n % 3 + 1)-0\(n % 9 + 1)-10T10:00:00+01:00",
                       thumb: nil, movie: n % 9 == 0, live: n % 4 == 0, favorite: n % 6 == 0, edited: n % 7 == 0,
                       hidden: false, albums: n % 5 == 0 ? ["Holiday"] : [], in_dest: n % 3 == 0)
        }
        return ImportPlan(source: "/Volumes/HDD/iPhone 13 Backup.photoslibrary", dest: "/Volumes/HDD/Trips.photoslibrary",
                          source_name: "iPhone 13 Backup", dest_name: "Trips", albums: ["Holiday", "Family"], items: items)
    }()

    static let sample: CleanupReport = {
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
