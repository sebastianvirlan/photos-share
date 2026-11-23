import Foundation
import Observation
import Photos

/// One row of `photos-dedupe --json`.
struct CleanupRow: Codable, Identifiable, Hashable {
    let uuid: String
    let name: String?
    let date: String
    let edited: Bool
    let thumb: String?
    let dest: String?
    let how: String?
    let dest_thumb: String?
    let reason: String?
    var id: String { uuid }
}

struct CleanupReport: Codable {
    let source: String
    let dest: String
    let source_name: String
    let dest_name: String
    let total: Int
    let all_verified: Bool
    let source_is_system: Bool
    let dest_is_system: Bool
    let matched: [CleanupRow]
    let edit_lost: [CleanupRow]
    let missing: [CleanupRow]
    let needs_review: [CleanupRow]
    let outcome: String?
}

enum CleanupGroup: String, CaseIterable, Identifiable {
    case matched, review, editLost, missing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matched: "In the destination"
        case .review: "Needs a look"
        case .editLost: "Edit didn’t come across"
        case .missing: "Not imported"
        }
    }
    var explanation: String {
        switch self {
        case .matched: "These photos are in the destination library and their files check out (present, same size, Live Photo and RAW parts included), so they’re safe to remove from the source."
        case .review: "These seemed to be in the destination, but a file check failed. Click one to see why. They’re kept."
        case .editLost: "These are in the destination, but without the edit you made in the source. They’re kept so you don’t lose the edit."
        case .missing: "These aren’t in the destination at all. They’re kept."
        }
    }
    var symbol: String {
        switch self {
        case .matched: "checkmark.circle.fill"
        case .review: "questionmark.circle.fill"
        case .editLost: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        }
    }
}

enum CleanupAction: String { case mark, delete, trash }

@MainActor @Observable
final class CleanupModel {
    static let shared = CleanupModel()
    enum State { case idle, comparing, ready, acting(CleanupAction), done(String), failed(String) }

    var source: URL?
    var dest: URL?
    private(set) var state: State = .idle
    private(set) var report: CleanupReport?
    var message: (ok: Bool, text: String)?

    /// What photos-dedupe is doing right now (while comparing or acting), and since when.
    struct Progress: Equatable { var phase = ""; var done = 0; var total = 0; var library = "" }
    private(set) var progress = Progress()
    private(set) var started = Date()
    private var process: Process?
    private var cancelling = false

    /// Step, title and detail for the current phase.
    var progressInfo: (step: Int, title: String, detail: String) {
        let p = progress
        let isSource = p.library == source?.deletingPathExtension().lastPathComponent
        switch p.phase {
        case "opening":
            return (isSource ? 1 : 2, "Opening “\(p.library)”",
                    "Photos’ database is read in one go: a minute or two for a big library on a hard drive.")
        case "reading":
            return (isSource ? 1 : 2, "Reading “\(p.library)”", "Noting each photo’s fingerprint, name, size and date.")
        case "matching":
            return (3, "Matching the two libraries", "")
        case "checking":
            return (3, "Checking the files of photos in both",
                    "Each copy is looked at on disk, so a photo is only called safe if its file really arrived.")
        case "thumbnails":
            return (4, "Finding previews", "")
        default:
            return (1, "Starting", "")
        }
    }

    /// Stops a comparison (nothing has changed yet, so this is always safe).
    func cancelCompare() {
        guard case .comparing = state else { return }
        cancelling = true
        process?.terminate()
    }

    var canCompare: Bool {
        guard let source, let dest else { return false }
        if case .comparing = state { return false }
        if case .acting = state { return false }
        return source != dest
    }

    /// Fill in both libraries (e.g. right after an import) and start fresh.
    func prepare(source: URL?, dest: URL?) {
        self.source = source
        self.dest = dest
        report = nil
        message = nil
        state = .idle
    }

    /// For `--snapshot` renders only: show a canned report without running the tools.
    func showForSnapshot(_ r: CleanupReport?, source: URL?, dest: URL?) {
        self.source = source
        self.dest = dest
        report = r
        state = r == nil ? .idle : .ready
    }

    func rows(_ g: CleanupGroup) -> [CleanupRow] {
        guard let r = report else { return [] }
        switch g {
        case .matched: return r.matched
        case .review: return r.needs_review
        case .editLost: return r.edit_lost
        case .missing: return r.missing
        }
    }

    func compare() async {
        guard let source, let dest else { return }
        state = .comparing
        message = nil
        cancelling = false
        do {
            report = try await dedupe([source.path, dest.path, "--json"])
            state = .ready
        } catch {
            if cancelling {
                state = report == nil ? .idle : .ready
            } else {
                report = nil
                state = .failed(error.localizedDescription)
            }
        }
        cancelling = false
    }

    /// Every action re-reads both libraries first, so it never acts on a stale comparison.
    func perform(_ action: CleanupAction) async {
        guard let source, let dest, report != nil else { return }
        state = .acting(action)
        do {
            let text: String
            switch action {
            case .mark, .trash:
                let flag = action == .mark ? "--mark" : "--trash-library"
                let r = try await dedupe([source.path, dest.path, "--json", flag, "--yes"])
                report = r
                text = r.outcome ?? "Done."
            case .delete:
                let fresh = try await dedupe([source.path, dest.path, "--json"])
                report = fresh
                text = try await PhotoKitDelete.run(fresh)
            }
            message = (true, text)
            state = .done(text)
        } catch {
            message = (false, error.localizedDescription)
            state = .ready  // nothing happened; the user can choose again
        }
    }

    /// Runs photos-dedupe, following its progress lines; the last other line is the result.
    private func dedupe(_ args: [String]) async throws -> CleanupReport {
        progress = Progress()
        started = Date()
        return try await withCheckedThrowingContinuation { cont in
            var result: Data?
            do {
                process = try Tools.stream("photos-dedupe", args + ["--progress"],
                    onLine: { [weak self] line in
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        if obj["event"] as? String == "progress" {
                            self?.progress = Progress(phase: obj["phase"] as? String ?? "",
                                                      done: obj["done"] as? Int ?? 0,
                                                      total: obj["total"] as? Int ?? 0,
                                                      library: obj["library"] as? String ?? "")
                        } else {
                            result = data
                        }
                    },
                    onExit: { [weak self] code, stderr in
                        self?.process = nil
                        if let result, let obj = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                           let e = obj["error"] as? String {
                            return cont.resume(throwing: CleanupFailure(e))
                        }
                        guard code == 0, let result else {
                            return cont.resume(throwing: CleanupFailure(
                                stderr.split(separator: "\n").last.map(String.init)
                                ?? "photos-dedupe failed (code \(code))."))
                        }
                        do {
                            cont.resume(returning: try JSONDecoder().decode(CleanupReport.self, from: result))
                        } catch {
                            cont.resume(throwing: CleanupFailure("Unexpected output from photos-dedupe: \(error.localizedDescription)"))
                        }
                    })
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// For `--snapshot` renders only.
    func showProgressForSnapshot(_ p: Progress, since: Date) {
        state = .comparing; progress = p; started = since
    }
}

struct CleanupFailure: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Deletes the verified photos with PhotoKit, from this app so macOS can show its dialog.
/// Same safety rules as the Python tool: the source must be the System Photo Library, every
/// photo must be found, and each one's capture date must match the verified one.
enum PhotoKitDelete {
    static func run(_ r: CleanupReport) async throws -> String {
        guard r.source_is_system else {
            throw CleanupFailure("“\(r.source_name)” isn’t the System Photo Library, so Photos won’t let apps delete from it. Use “Mark in Photos”, or make it the System Photo Library in Photos → Settings → General.")
        }
        let items = r.matched
        guard !items.isEmpty else { throw CleanupFailure("Nothing verified, so nothing to delete.") }
        try await delete(items.map { ($0.uuid, $0.date) })
        return "Deleted \(items.count) photos from “\(r.source_name)”. They’re in Recently Deleted for 30 days."
    }

    /// Deletes photos from the System Photo Library after checking each is still the photo
    /// that was verified (same capture date). All or nothing; they go to Recently Deleted.
    static func delete(_ items: [(uuid: String, date: String)]) async throws {

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw CleanupFailure("Photos access wasn’t granted (System Settings → Privacy & Security → Photos).")
        }

        let ids = items.map { "\($0.uuid)/L0/001" }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard found.count == items.count else {
            throw CleanupFailure("Only \(found.count) of \(items.count) photos were found in the System Photo Library; nothing was deleted.")
        }
        let expected = Dictionary(items.map { ($0.uuid, epoch($0.date)) }, uniquingKeysWith: { a, _ in a })
        var mismatch: String?
        found.enumerateObjects { asset, _, stop in
            let uuid = String(asset.localIdentifier.split(separator: "/").first ?? "")
            if let want = expected[uuid] ?? nil, let got = asset.creationDate?.timeIntervalSince1970,
               abs(got - want) > 1.5 {
                mismatch = uuid
                stop.pointee = true
            }
        }
        if let mismatch {
            throw CleanupFailure("Photo \(mismatch) doesn’t match the one verified (different date); nothing was deleted.")
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(found)
            }
        } catch {
            throw CleanupFailure("Nothing was deleted: \(error.localizedDescription)")
        }
    }

    private static func epoch(_ iso: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d.timeIntervalSince1970 }
        // No UTC offset in the string: treat as local time, as Python's fromisoformat would.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: iso)?.timeIntervalSince1970
    }
}
