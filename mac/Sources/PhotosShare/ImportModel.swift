import Foundation
import Observation

struct ImportItem: Codable, Identifiable, Hashable {
    let uuid: String
    let name: String?
    let date: String
    let thumb: String?
    let movie: Bool
    let live: Bool
    let favorite: Bool
    let edited: Bool
    let hidden: Bool
    let albums: [String]
    let in_dest: Bool
    var id: String { uuid }
    var year: String { String(date.prefix(4)) }
}

struct ImportPlan: Codable {
    let source: String
    let dest: String
    let source_name: String
    let dest_name: String
    let albums: [String]
    let items: [ImportItem]
    var dest_is_system: Bool? = nil
}

struct ImportSummary: Codable {
    struct Problem: Codable, Hashable { let uuid: String; let name: String?; let reason: String }
    struct Named: Codable, Hashable { let uuid: String; let name: String? }
    let imported: Int
    let requested: Int
    let failed: [Problem]
    let skipped_edited: [Named]
}

enum EditedMode: String, CaseIterable, Identifiable {
    case skip, flatten, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skip: "Skip edited photos"
        case .flatten: "Import as they look now"
        case .both: "Import both versions"
        }
    }
    var detail: String {
        switch self {
        case .skip: "Nothing is lost: import them later with the destination set as the System Photo Library, to keep their edits."
        case .flatten: "The edit is baked into the photo and can’t be reverted in the destination."
        case .both: "The edited look and the untouched original arrive as two separate photos."
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos"
    var id: String { rawValue }
}

@MainActor @Observable
final class ImportModel {
    static let shared = ImportModel()
    enum State { case idle, loading, ready, importing, done, failed(String) }

    var source: URL?
    var dest: URL?
    var includeHidden = false
    private(set) var state: State = .idle
    private(set) var plan: ImportPlan?
    var selection: Set<String> = []
    var editedMode: EditedMode = .skip

    // Filters
    var onlyNew = true
    var album: String?
    var year: String?
    var media: MediaFilter = .all
    var favoritesOnly = false

    private(set) var phase = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var summary: ImportSummary?
    private var process: Process?
    private var cancelled = false

    /// Edits can be kept only when the destination is the System Photo Library (PhotoKit).
    var keepsEdits: Bool { plan?.dest_is_system == true }

    /// How many of the selection will be imported.
    var importCount: Int {
        keepsEdits || editedMode != .skip ? selection.count : selection.count - selectedEdited
    }

    var canLoad: Bool {
        guard let source, let dest, source != dest else { return false }
        if case .loading = state { return false }
        if case .importing = state { return false }
        return true
    }

    var visible: [ImportItem] {
        (plan?.items ?? []).filter { i in
            (!onlyNew || !i.in_dest)
                && (album == nil || i.albums.contains(album!))
                && (year == nil || i.year == year)
                && (media == .all || (media == .videos) == i.movie)
                && (!favoritesOnly || i.favorite)
        }
    }

    var years: [String] { Array(Set((plan?.items ?? []).map(\.year))).sorted(by: >) }
    var selectedItems: [ImportItem] { (plan?.items ?? []).filter { selection.contains($0.uuid) } }
    var selectedEdited: Int { selectedItems.filter(\.edited).count }
    var alreadyInDest: Int { (plan?.items ?? []).filter(\.in_dest).count }

    func load() async {
        guard let source, let dest else { return }
        state = .loading
        summary = nil
        var args = [source.path, dest.path, "--plan", "--json"]
        if includeHidden { args.append("--hidden") }
        do {
            let (code, out, err) = try await Tools.run("photos-import", args)
            if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
               let message = obj["message"] as? String, obj["event"] as? String == "error" {
                state = .failed(message)
                return
            }
            guard code == 0 else {
                state = .failed(err.split(separator: "\n").last.map(String.init) ?? "photos-import failed")
                return
            }
            let p = try JSONDecoder().decode(ImportPlan.self, from: out)
            plan = p
            selection = Set(p.items.filter { !$0.in_dest }.map(\.uuid))  // everything new
            album = nil; year = nil
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func toggle(_ item: ImportItem) {
        if selection.contains(item.uuid) { selection.remove(item.uuid) } else { selection.insert(item.uuid) }
    }
    func selectVisible() { selection.formUnion(visible.map(\.uuid)) }
    func deselectVisible() { selection.subtract(visible.map(\.uuid)) }

    func start() {
        guard source != nil, dest != nil, !selection.isEmpty else { return }
        cancelled = false
        state = .importing
        phase = "Starting"
        done = 0
        total = selection.count
        summary = nil
        if keepsEdits {
            Task { await importKeepingEdits() }
        } else {
            importThroughPhotos()
        }
    }

    private func writeSelection() throws -> URL {
        let list = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-import-\(UUID().uuidString).txt")
        try selection.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    /// Photos' scripting import: edit recipes are ignored, so edited photos are skipped or flattened.
    private func importThroughPhotos() {
        guard let source, let dest else { return }
        let list: URL
        do { list = try writeSelection() } catch {
            state = .failed("Couldn’t prepare the import: \(error.localizedDescription)")
            return
        }
        do {
            process = try Tools.stream(
                "photos-import",
                [source.path, dest.path, "--uuids-file", list.path, "--edited", editedMode.rawValue, "--json"],
                onLine: { [weak self] line in self?.handle(line) },
                onExit: { [weak self] code, stderr in
                    try? FileManager.default.removeItem(at: list)
                    self?.finished(code, stderr)
                })
        } catch {
            state = .failed("Couldn’t run photos-import: \(error.localizedDescription)")
        }
    }

    /// Creates the photos ourselves (PhotoKit) with all their parts, so edits stay editable,
    /// then lets photos-import check them and add titles, captions and keywords.
    private func importKeepingEdits() async {
        guard let source, let dest else { return }
        do {
            phase = "Preparing"
            let list = try writeSelection()
            defer { try? FileManager.default.removeItem(at: list) }
            let (code, out, err) = try await Tools.run("photos-import", [source.path, dest.path, "--parts", "--uuids-file", list.path, "--json"])
            if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
               obj["event"] as? String == "error" {
                throw PhotoKitImport.Failure(obj["message"] as? String ?? "photos-import failed")
            }
            guard code == 0 else {
                throw PhotoKitImport.Failure(err.split(separator: "\n").last.map(String.init) ?? "photos-import failed")
            }
            let manifest = try JSONDecoder().decode(PhotoKitImport.Manifest.self, from: out)
            try await PhotoKitImport.authorize()

            var run = PhotoKitImport.Run(requested: selection.count, failed: manifest.problems)
            let albums = try await PhotoKitImport.albums(named: Set(manifest.items.flatMap(\.albums)))
            phase = "Importing"
            done = manifest.problems.count
            var rest = manifest.items[...]
            while !rest.isEmpty && !cancelled {
                let batch = Array(rest.prefix(PhotoKitImport.batchSize))
                rest = rest.dropFirst(batch.count)
                await PhotoKitImport.create(batch, albums: albums, into: &run)
                done += batch.count
            }
            if cancelled {
                run.requested = run.created.count + run.failed.count
            }

            let runFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("photos-import-run-\(UUID().uuidString).json")
            try JSONEncoder().encode(run).write(to: runFile)
            phase = "Checking"
            process = try Tools.stream(
                "photos-import", [source.path, dest.path, "--finish", runFile.path, "--json"],
                onLine: { [weak self] line in self?.handle(line) },
                onExit: { [weak self] code, stderr in
                    try? FileManager.default.removeItem(at: runFile)
                    self?.finished(code, stderr)
                })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        cancelled = true        // stops creating photos after the current batch
        process?.interrupt()
    }

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "start":
            total = obj["total"] as? Int ?? total
        case "progress":
            done = obj["done"] as? Int ?? done
            total = obj["total"] as? Int ?? total
            switch obj["phase"] as? String {
            case "opening": phase = "Opening the destination in Photos"
            case "checking": phase = "Checking the imported photos"
            case "details": phase = "Adding titles, captions and keywords in Photos"
            default: phase = "Importing"
            }
        case "done":
            summary = try? JSONDecoder().decode(ImportSummary.self, from: data)
            state = .done
        case "error":
            state = .failed(obj["message"] as? String ?? "Import failed.")
        case "cancelled":
            state = .failed("Import cancelled. Photos already imported stay in the destination.")
        default: break
        }
    }

    private func finished(_ code: Int32, _ stderr: String) {
        process = nil
        if case .importing = state {
            state = .failed(stderr.split(separator: "\n").last.map(String.init)
                            ?? "photos-import stopped unexpectedly (code \(code)).")
        }
    }

    /// For `--snapshot` renders only.
    func showForSnapshot(_ p: ImportPlan?, source: URL?, dest: URL?) {
        self.source = source; self.dest = dest; plan = p
        selection = Set((p?.items ?? []).filter { !$0.in_dest }.map(\.uuid))
        state = p == nil ? .idle : .ready
    }
}
