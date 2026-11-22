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
    enum State { case idle, comparing, ready, acting(CleanupAction), done(String), failed(String) }

    var source: URL?
    var dest: URL?
    private(set) var state: State = .idle
    private(set) var report: CleanupReport?
    var message: (ok: Bool, text: String)?

    var canCompare: Bool {
        guard let source, let dest else { return false }
        if case .comparing = state { return false }
        if case .acting = state { return false }
        return source != dest
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
        do {
            report = try await dedupe([source.path, dest.path, "--json"])
            state = .ready
        } catch {
            report = nil
            state = .failed(error.localizedDescription)
        }
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

    private func dedupe(_ args: [String]) async throws -> CleanupReport {
        let (code, out, err) = try await Tools.run("photos-dedupe", args)
        if let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any],
           let e = obj["error"] as? String {
            throw CleanupFailure(e)
        }
        guard code == 0 else {
            throw CleanupFailure(err.split(separator: "\n").last.map(String.init)
                                 ?? "photos-dedupe failed (code \(code)).")
        }
        do {
            return try JSONDecoder().decode(CleanupReport.self, from: out)
        } catch {
            throw CleanupFailure("Unexpected output from photos-dedupe: \(error.localizedDescription)")
        }
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

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            throw CleanupFailure("Photos access wasn’t granted (System Settings → Privacy & Security → Photos).")
        }

        let ids = items.map { "\($0.uuid)/L0/001" }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard found.count == items.count else {
            throw CleanupFailure("Only \(found.count) of \(items.count) photos were found in the System Photo Library; nothing was deleted.")
        }
        let expected = Dictionary(uniqueKeysWithValues: items.map { ($0.uuid, epoch($0.date)) })
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
        return "Deleted \(items.count) photos from “\(r.source_name)”. They’re in Recently Deleted for 30 days."
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
