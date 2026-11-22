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
    var in_dest: Bool
    var original: String? = nil
    var id: String { uuid }
    var year: String { String(date.prefix(4)) }
}

struct ImportPlan: Codable {
    let source: String
    let dest: String
    let source_name: String
    let dest_name: String
    let albums: [String]
    var items: [ImportItem]
    var dest_is_system: Bool? = nil
}

struct ImportSummary: Codable {
    struct Problem: Codable, Hashable { let uuid: String; let name: String?; let reason: String }
    struct Named: Codable, Hashable { let uuid: String; let name: String? }
    let imported: Int
    let requested: Int
    let failed: [Problem]
    let skipped_edited: [Named]
    var imported_uuids: [String]? = nil
    var cancelled: Bool? = nil
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
    enum State { case idle, loading, ready, failed(String) }

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
    /// The last import's result, shown above the bottom bar until dismissed or the next import.
    private(set) var summary: ImportSummary?
    private(set) var importError: String?
    /// Importing runs under the grid, so you can keep browsing and selecting.
    private(set) var isImporting = false
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
        return !isImporting
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
        importError = nil
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

    /// The last photo clicked: the start of a Shift-click range.
    private(set) var anchor: String?

    func toggle(_ item: ImportItem) {
        if selection.contains(item.uuid) { selection.remove(item.uuid) } else { selection.insert(item.uuid) }
        anchor = item.uuid
    }

    /// Click toggles one photo; Shift-click gives everything from the last clicked photo to
    /// this one the state that last photo has now (selected, or deselected).
    func click(_ item: ImportItem, extendingRange: Bool) {
        let shown = visible
        guard extendingRange, let anchor,
              let from = shown.firstIndex(where: { $0.uuid == anchor }),
              let to = shown.firstIndex(where: { $0.uuid == item.uuid }) else {
            toggle(item)
            return
        }
        let range = shown[min(from, to)...max(from, to)].map(\.uuid)
        if selection.contains(anchor) { selection.formUnion(range) } else { selection.subtract(range) }
    }

    enum MarqueeMode { case replace, add, remove }

    /// Selection while dragging a box: `base` is the selection when the drag started.
    func marquee(base: Set<String>, touched: Set<String>, mode: MarqueeMode) {
        switch mode {
        case .replace: selection = touched
        case .add: selection = base.union(touched)
        case .remove: selection = base.subtracting(touched)
        }
    }
    func selectVisible() { selection.formUnion(visible.map(\.uuid)) }
    func deselectVisible() { selection.subtract(visible.map(\.uuid)) }

    func start() {
        guard source != nil, dest != nil, !selection.isEmpty, !isImporting else { return }
        let uuids = selection
        cancelled = false
        isImporting = true
        importError = nil
        summary = nil
        phase = "Starting"
        done = 0
        total = uuids.count
        if keepsEdits {
            Task { await importKeepingEdits(uuids) }
        } else {
            importThroughPhotos(uuids)
        }
    }

    func dismissResult() {
        summary = nil
        importError = nil
    }

    private func writeSelection(_ uuids: Set<String>) throws -> URL {
        let list = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-import-\(UUID().uuidString).txt")
        try uuids.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    private func stopImporting(_ error: String) {
        importError = error
        isImporting = false
        process = nil
    }

    /// What was imported is now in the destination: mark it so, and take it out of the selection.
    private func apply(_ result: ImportSummary) {
        let imported = Set(result.imported_uuids ?? [])
        guard var p = plan, !imported.isEmpty else { return }
        for i in p.items.indices where imported.contains(p.items[i].uuid) { p.items[i].in_dest = true }
        plan = p
        selection.subtract(imported)
    }

    /// Photos' scripting import: edit recipes are ignored, so edited photos are skipped or flattened.
    private func importThroughPhotos(_ uuids: Set<String>) {
        guard let source, let dest else { return }
        let list: URL
        do { list = try writeSelection(uuids) } catch {
            stopImporting("Couldn’t prepare the import: \(error.localizedDescription)")
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
            stopImporting("Couldn’t run photos-import: \(error.localizedDescription)")
        }
    }

    /// Creates the photos ourselves (PhotoKit) with all their parts, so edits stay editable,
    /// then lets photos-import check them and add titles, captions and keywords.
    private func importKeepingEdits(_ uuids: Set<String>) async {
        guard let source, let dest else { return }
        do {
            phase = "Preparing"
            let list = try writeSelection(uuids)
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

            var run = PhotoKitImport.Run(requested: uuids.count, failed: manifest.problems)
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
                run.cancelled = true
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
            stopImporting(error.localizedDescription)
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
            if let result = try? JSONDecoder().decode(ImportSummary.self, from: data) {
                summary = result
                apply(result)
            }
            isImporting = false
        case "error":
            stopImporting(obj["message"] as? String ?? "Import failed.")
        case "cancelled":
            stopImporting("Import cancelled. Photos already imported stay in the destination; Reload to see which.")
        default: break
        }
    }

    private func finished(_ code: Int32, _ stderr: String) {
        process = nil
        if isImporting {
            stopImporting(stderr.split(separator: "\n").last.map(String.init)
                          ?? "photos-import stopped unexpectedly (code \(code)).")
        }
    }

    /// For `--snapshot` renders only.
    func showProgressForSnapshot(done: Int, total: Int) {
        isImporting = true; phase = "Importing"; self.done = done; self.total = total
    }

    /// For `--snapshot` renders only.
    func showResultForSnapshot(_ result: ImportSummary) {
        isImporting = false; summary = result; apply(result)
    }

    /// For `--snapshot` renders only.
    func showForSnapshot(_ p: ImportPlan?, source: URL?, dest: URL?) {
        self.source = source; self.dest = dest; plan = p
        selection = Set((p?.items ?? []).filter { !$0.in_dest }.map(\.uuid))
        state = p == nil ? .idle : .ready
    }
}
