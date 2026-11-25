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
    struct Problem: Codable, Hashable {
        let uuid: String; let name: String?; let reason: String
        var already: Bool? = nil   // already in the destination: skipped, not a failure
    }
    struct Named: Codable, Hashable { let uuid: String; let name: String? }
    let imported: Int
    let requested: Int
    let failed: [Problem]
    let skipped_edited: [Named]
    var imported_uuids: [String]? = nil
    var cancelled: Bool? = nil
    var stopped: String? = nil
    var already_in_dest: [String]? = nil
    /// Real problems, leaving out photos that were skipped because they're already there.
    var problems: [Problem] { failed.filter { $0.already != true } }
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
    /// What the last import was asked for, and which of it didn't arrive (to retry).
    private var lastRequested: Set<String> = []
    private(set) var notImported: Set<String> = []
    /// Importing runs under the grid, so you can keep browsing and selecting.
    private(set) var isImporting = false {
        didSet { if !isImporting { importing = [] } }
    }
    /// The photos in the import that's running: shown as importing, and can't be selected.
    private(set) var importing: Set<String> = []
    /// Photos added while an import runs: imported together as soon as it finishes well.
    /// If it stops on a problem or is cancelled, they wait for Start Queue.
    private(set) var queued: Set<String> = []
    /// Importing or queued: shown with their state, and not selectable.
    var locked: Set<String> { importing.union(queued) }
    /// Which import is current: signals from an earlier one (its tool exiting, its last
    /// batch) are ignored, so they can't stop or miscount the one that followed it.
    private var generation = 0
    /// Set when an import finished well: the queue starts once its tool has exited.
    private var queueAfterExit = false
    /// Libraries can't change while photos are on their way or waiting.
    var busy: Bool { isImporting || !queued.isEmpty }
    private var process: Process?
    private var cancelled = false
    /// Imports cut short before they were checked (see `PhotoKitImport.Journal`).
    private(set) var interrupted: [PhotoKitImport.Journal] = PhotoKitImport.Journal.all()
    /// The journal being finished now: removed once photos-import reports it's done.
    private var finishing: PhotoKitImport.Journal?

    /// Edits can be kept only when the destination is the System Photo Library (PhotoKit).
    var keepsEdits: Bool { plan?.dest_is_system == true }

    /// How many of the selection will be imported.
    var importCount: Int {
        keepsEdits || editedMode != .skip ? selection.count : selection.count - selectedEdited
    }

    var canLoad: Bool {
        guard let source, let dest, source != dest else { return false }
        if case .loading = state { return false }
        return !busy
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
        guard !importing.contains(item.uuid) else { return }
        if queued.contains(item.uuid) {   // clicking a queued photo takes it out of the queue
            queued.remove(item.uuid)
            return
        }
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
        if selection.contains(anchor) { selection.formUnion(Set(range).subtracting(locked)) }
        else { selection.subtract(range) }
    }

    enum MarqueeMode { case replace, add, remove }

    /// Selection while dragging a box: `base` is the selection when the drag started.
    func marquee(base: Set<String>, touched: Set<String>, mode: MarqueeMode) {
        switch mode {
        case .replace: selection = touched.subtracting(locked)
        case .add: selection = base.union(touched.subtracting(locked))
        case .remove: selection = base.subtracting(touched)
        }
    }
    func selectVisible() { selection.formUnion(Set(visible.map(\.uuid)).subtracting(locked)) }
    func deselectVisible() { selection.subtract(visible.map(\.uuid)) }

    func start() {
        guard !selection.isEmpty, !isImporting else { return }
        let uuids = selection
        selection.subtract(uuids)   // they're on their way; select more meanwhile
        begin(uuids)
    }

    /// While importing: the selection waits, and is imported when this import finishes.
    func enqueue() {
        guard isImporting else { return start() }
        let add = selection.subtracting(importing)
        queued.formUnion(add)
        selection.subtract(add)
        ImportLog.write("  queued \(add.count) more (\(queued.count) waiting)")
    }

    func clearQueue() {
        ImportLog.write("  queue cleared (\(queued.count) photos)")
        queued = []
    }

    /// Imports what's queued (also automatically, when an import finishes well).
    func startQueue() {
        guard !isImporting else { return }
        let inDest = Set((plan?.items ?? []).filter(\.in_dest).map(\.uuid))
        let next = queued.subtracting(inDest)
        queued = []
        guard !next.isEmpty else { return }
        begin(next)
    }

    private func begin(_ uuids: Set<String>) {
        guard source != nil, dest != nil, !uuids.isEmpty, !isImporting else { return }
        generation += 1
        queueAfterExit = false
        lastRequested = uuids
        notImported = []
        cancelled = false
        isImporting = true
        importing = uuids
        importError = nil
        summary = nil
        phase = "Starting"
        done = 0
        total = uuids.count
        ImportLog.write("=== Import \(uuids.count) from “\(source!.path)” into “\(dest!.path)” — "
                        + (keepsEdits ? "creating them with PhotoKit (destination is the System Photo Library)"
                           : "through Photos’ import (destination isn’t the System Photo Library; edited: \(editedMode.rawValue))"))
        ImportLog.write("  selected: " + uuids.sorted().joined(separator: ", "))
        if keepsEdits {
            Task { await importKeepingEdits(uuids) }
        } else {
            importThroughPhotos(uuids)
        }
    }

    func dismissResult() {
        summary = nil
        importError = nil
        notImported = []
    }

    private func writeSelection(_ uuids: Set<String>) throws -> URL {
        let list = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-import-\(UUID().uuidString).txt")
        try uuids.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        return list
    }

    private func stopImporting(_ error: String) {
        ImportLog.write("  stopped: \(error)")
        importError = error
        isImporting = false
        process = nil
        finishing = nil   // its journal stays, to finish later
        interrupted = PhotoKitImport.Journal.all()
        // Without a result we can't tell what arrived: offer only what's still not in the destination.
        let inDest = Set((plan?.items ?? []).filter(\.in_dest).map(\.uuid))
        notImported = lastRequested.subtracting(inDest)
    }

    func selectNotImported() {
        selection.formUnion(notImported.subtracting(locked))
        notImported = []
    }

    /// What was imported is now in the destination: mark it so, and take it out of the selection.
    private func apply(_ result: ImportSummary) {
        let imported = Set(result.imported_uuids ?? []).union(result.already_in_dest ?? [])
        notImported = lastRequested.subtracting(imported)
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
                onLine: { [weak self, gen = generation] line in ImportLog.tool(line); self?.handle(line, gen) },
                onExit: { [weak self, gen = generation] code, stderr in
                    try? FileManager.default.removeItem(at: list)
                    ImportLog.write("  photos-import exited \(code)" + (stderr.isEmpty ? "" : ": \(stderr.suffix(2000))"))
                    self?.finished(code, stderr, gen)
                })
        } catch {
            stopImporting("Couldn’t run photos-import: \(error.localizedDescription)")
        }
    }

    /// Creates the photos ourselves (PhotoKit) with all their parts, so edits stay editable,
    /// then lets photos-import check them and add titles, captions and keywords.
    private func importKeepingEdits(_ uuids: Set<String>) async {
        guard let source, let dest else { return }
        let gen = generation
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
            guard gen == generation else { return }
            let manifest = try JSONDecoder().decode(PhotoKitImport.Manifest.self, from: out)
            ImportLog.write("  found in the source: \(manifest.items.count) to create, \(manifest.problems.count) can’t be")
            for p in manifest.problems { ImportLog.write("    \(p.name ?? p.uuid): \(p.reason)") }
            try await PhotoKitImport.authorize()

            var journal = PhotoKitImport.Journal(
                source: source.path, dest: dest.path, started: Date(),
                run: PhotoKitImport.Run(requested: uuids.count, failed: manifest.problems))
            let albums = try await PhotoKitImport.albums(named: Set(manifest.items.flatMap(\.albums)))
            phase = "Importing"
            done = manifest.problems.count
            var refused = 0
            var rest = manifest.items[...]
            while !rest.isEmpty && !cancelled && gen == generation {
                let batch = Array(rest.prefix(PhotoKitImport.batchSize))
                rest = rest.dropFirst(batch.count)
                let before = journal.run.created.count
                await PhotoKitImport.create(batch, albums: albums, into: &journal.run)
                ImportLog.write("  batch of \(batch.count): created \(journal.run.created.count - before)")
                for f in journal.run.failed.suffix(batch.count - (journal.run.created.count - before)) {
                    ImportLog.write("    \(f.name ?? f.uuid): \(f.reason)")
                }
                done += batch.count
                refused = journal.run.created.count > before ? 0 : refused + batch.count
                try? journal.save()   // if the app stops now, the next launch can finish this
                if refused >= PhotoKitImport.stopAfter && !rest.isEmpty {
                    journal.run.refused = refused
                    break
                }
            }
            guard gen == generation else {   // stopped meanwhile: keep its journal to finish later
                try? journal.save()
                return
            }
            if cancelled || journal.run.refused != nil {
                journal.run.requested = journal.run.created.count + journal.run.failed.count
                journal.run.cancelled = cancelled
            }
            try journal.save()
            finishRun(journal)
        } catch {
            if gen == generation { stopImporting(error.localizedDescription) }
        }
    }

    /// Checks what a run created and adds titles, captions and keywords (photos-import --finish).
    private func finishRun(_ journal: PhotoKitImport.Journal) {
        finishing = journal
        phase = "Checking"
        do {
            process = try Tools.stream(
                "photos-import", [journal.source, journal.dest, "--finish", journal.file.path, "--json"],
                onLine: { [weak self, gen = generation] line in ImportLog.tool(line); self?.handle(line, gen) },
                onExit: { [weak self, gen = generation] code, stderr in
                    ImportLog.write("  photos-import --finish exited \(code)" + (stderr.isEmpty ? "" : ": \(stderr.suffix(2000))"))
                    self?.finished(code, stderr, gen)
                })
        } catch {
            stopImporting("Couldn’t run photos-import: \(error.localizedDescription)")
        }
    }

    /// Finishes an import that was cut short: checks its photos and copies their details.
    func finishInterrupted(_ journal: PhotoKitImport.Journal) {
        guard !isImporting else { return }
        generation += 1
        queueAfterExit = false
        lastRequested = Set(journal.run.created.map(\.source_uuid))
        notImported = []
        cancelled = false
        isImporting = true
        importing = lastRequested
        importError = nil
        summary = nil
        done = 0
        total = journal.run.created.count
        finishRun(journal)
    }

    func discardInterrupted(_ journal: PhotoKitImport.Journal) {
        journal.remove()
        interrupted = PhotoKitImport.Journal.all()
    }

    func cancel() {
        cancelled = true        // stops creating photos after the current batch
        process?.interrupt()
    }

    private func handle(_ line: String, _ gen: Int) {
        guard gen == generation, let data = line.data(using: .utf8),
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
            case "verifying": phase = "Looking for the imported photos in the destination"
            case "details": phase = "Adding titles, captions and keywords in Photos"
            default: phase = "Importing"
            }
        case "done":
            if let result = try? JSONDecoder().decode(ImportSummary.self, from: data) {
                summary = result
                apply(result)
            }
            finishing?.remove()
            finishing = nil
            interrupted = PhotoKitImport.Journal.all()
            isImporting = false
            // The queue goes next (once this import's tool has exited), unless it stopped on a problem.
            queueAfterExit = !queued.isEmpty && summary?.stopped == nil && summary?.cancelled != true
        case "error":
            stopImporting(obj["message"] as? String ?? "Import failed.")
        case "cancelled":
            stopImporting("Import cancelled. Photos already imported stay in the destination; Reload to see which.")
        default: break
        }
    }

    private func finished(_ code: Int32, _ stderr: String, _ gen: Int) {
        guard gen == generation else { return }   // an earlier import's tool
        process = nil
        if isImporting {
            stopImporting(stderr.split(separator: "\n").last.map(String.init)
                          ?? "photos-import stopped unexpectedly (code \(code)).")
        } else if queueAfterExit {
            queueAfterExit = false
            ImportLog.write("  starting the queue: \(queued.count) photos")
            startQueue()
        }
    }

    /// For `--snapshot` renders only.
    func showQueueForSnapshot(_ n: Int) {
        queued = Set((plan?.items ?? []).filter { !$0.in_dest && !importing.contains($0.uuid) }.prefix(n).map(\.uuid))
        selection.subtract(queued)
    }
    func showInterruptedForSnapshot(_ j: [PhotoKitImport.Journal]) { interrupted = j }

    /// For `--snapshot` renders only.
    func showProgressForSnapshot(done: Int, total: Int) {
        isImporting = true; phase = "Importing"; self.done = done; self.total = total
        importing = Set((plan?.items ?? []).filter { !$0.in_dest }.prefix(total).map(\.uuid))
    }

    /// For `--snapshot` renders only.
    func showResultForSnapshot(_ result: ImportSummary, requested: Set<String>) {
        isImporting = false; summary = result; lastRequested = requested; apply(result)
    }

    /// For `--snapshot` renders only.
    func showForSnapshot(_ p: ImportPlan?, source: URL?, dest: URL?) {
        self.source = source; self.dest = dest; plan = p
        selection = Set((p?.items ?? []).filter { !$0.in_dest }.map(\.uuid))
        state = p == nil ? .idle : .ready
    }
}
