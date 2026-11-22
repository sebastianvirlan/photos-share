import Foundation
import Observation

struct DupCopy: Codable, Identifiable, Hashable {
    let uuid: String
    let name: String?
    let date: String
    let added: String
    let thumb: String?
    let original: String?
    let width: Int
    let height: Int
    let size: Int
    let movie: Bool
    let live: Bool
    let edited: Bool
    let favorite: Bool
    let hidden: Bool
    let albums: [String]
    let keywords: [String]
    let title: String?
    let description: String?
    let has_location: Bool
    let distance: Int
    var id: String { uuid }
}

struct DupGroup: Codable, Identifiable, Hashable {
    let kind: String          // "exact" or "near"
    var keep: String
    let copies: [DupCopy]
    var id: String { copies.map(\.uuid).min() ?? keep }
    var exact: Bool { kind == "exact" }
    var extras: [DupCopy] { copies.filter { $0.uuid != keep } }
}

enum DupFilter: String, CaseIterable, Identifiable {
    case all = "All", exact = "Exact copies", near = "Look alike"
    var id: String { rawValue }
}

@MainActor @Observable
final class DuplicatesModel {
    static let shared = DuplicatesModel()
    enum State: Equatable { case idle, scanning, ready, working, failed(String) }

    var library: URL?
    var includeHidden = false
    private(set) var state: State = .idle
    private(set) var phase = ""
    private(set) var done = 0
    private(set) var total = 0

    private(set) var groups: [DupGroup] = []
    private(set) var libraryName = ""
    private(set) var isSystem = false
    /// Groups to resolve. Exact copies start chosen; look-alikes wait for you to check them.
    var chosen: Set<String> = []
    var filter: DupFilter = .all
    private(set) var message: (text: String, ok: Bool)?
    private var process: Process?

    var shown: [DupGroup] {
        groups.filter { filter == .all || (filter == .exact) == $0.exact }
    }
    var exactCount: Int { groups.filter(\.exact).count }
    var nearCount: Int { groups.count - exactCount }
    var chosenGroups: [DupGroup] { groups.filter { chosen.contains($0.id) } }
    var copiesToRemove: Int { chosenGroups.reduce(0) { $0 + $1.extras.count } }
    var canScan: Bool { library != nil && state != .scanning && state != .working }

    func setKeep(_ copy: DupCopy, in group: DupGroup) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[i].keep = copy.uuid
    }

    func toggle(_ group: DupGroup) {
        if chosen.contains(group.id) { chosen.remove(group.id) } else { chosen.insert(group.id) }
    }
    func chooseAllExact() { chosen.formUnion(groups.filter(\.exact).map(\.id)) }
    func chooseShown() { chosen.formUnion(shown.map(\.id)) }
    func chooseNone() { chosen.removeAll() }

    // MARK: - Scanning

    func scan() {
        guard let library, canScan else { return }
        state = .scanning
        message = nil
        phase = "Reading the library"
        done = 0
        total = 0
        var args = [library.path, "--scan", "--json"]
        if includeHidden { args.append("--hidden") }
        do {
            process = try Tools.stream("photos-duplicates", args,
                onLine: { [weak self] in self?.handleScan($0) },
                onExit: { [weak self] code, stderr in
                    guard let self else { return }
                    self.process = nil
                    if self.state == .scanning {
                        self.state = .failed(stderr.split(separator: "\n").last.map(String.init)
                                             ?? "photos-duplicates stopped unexpectedly (code \(code)).")
                    }
                })
        } catch {
            state = .failed("Couldn’t run photos-duplicates: \(error.localizedDescription)")
        }
    }

    func cancelScan() {
        process?.terminate()
        process = nil
        state = groups.isEmpty ? .idle : .ready
    }

    private struct ScanResult: Decodable {
        let groups: [DupGroup]
        let library_name: String
        let system: Bool
    }

    private func handleScan(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "progress":
            done = obj["done"] as? Int ?? 0
            total = obj["total"] as? Int ?? 0
            phase = (obj["phase"] as? String) == "comparing" ? "Comparing photos" : "Reading the library"
        case "result":
            guard let r = try? JSONDecoder().decode(ScanResult.self, from: data) else {
                state = .failed("Couldn’t read the scan results.")
                return
            }
            groups = r.groups
            libraryName = r.library_name
            isSystem = r.system
            chosen = Set(r.groups.filter(\.exact).map(\.id))
            filter = .all
            state = .ready
        case "error":
            state = .failed(obj["message"] as? String ?? "Scan failed.")
        default: break
        }
    }

    // MARK: - Resolving

    private struct Resolved: Decodable {
        struct Deletion: Decodable { let uuid: String; let date: String }
        struct Problem: Decodable { let uuid: String; let reason: String }
        let system: Bool
        let merged: Int
        let marked: Int
        let album: String
        let delete: [Deletion]
        let failed: [Problem]
    }

    func resolve() {
        guard let library else { return }
        let work = chosenGroups
        guard !work.isEmpty else { return }
        let decisions = work.map { ["keep": $0.keep, "remove": $0.extras.map(\.uuid)] as [String: Any] }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-duplicates-\(UUID().uuidString).json")
        do {
            try JSONSerialization.data(withJSONObject: decisions).write(to: file)
        } catch {
            message = ("Couldn’t prepare: \(error.localizedDescription)", false)
            return
        }
        state = .working
        message = nil
        phase = "Checking the library again"
        var result: Resolved?
        var failure: String?
        do {
            process = try Tools.stream("photos-duplicates", [library.path, "--resolve", file.path, "--json"],
                onLine: { [weak self] line in
                    guard let self, let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    switch obj["event"] as? String {
                    case "progress":
                        self.phase = (obj["phase"] as? String) == "opening"
                            ? "Opening “\(self.libraryName)” in Photos" : "Copying details onto the kept photos"
                    case "done": result = try? JSONDecoder().decode(Resolved.self, from: data)
                    case "error": failure = obj["message"] as? String
                    default: break
                    }
                },
                onExit: { [weak self] _, stderr in
                    try? FileManager.default.removeItem(at: file)
                    guard let self else { return }
                    self.process = nil
                    Task { await self.finish(work, result, failure ?? (result == nil ? stderr.split(separator: "\n").last.map(String.init) : nil)) }
                })
        } catch {
            state = .ready
            message = ("Couldn’t run photos-duplicates: \(error.localizedDescription)", false)
        }
    }

    private func finish(_ work: [DupGroup], _ r: Resolved?, _ failure: String?) async {
        guard let r else {
            state = .ready
            message = (failure ?? "Nothing was changed.", false)
            return
        }
        let failedKeeps = Set(r.failed.map(\.uuid))
        var deleted = 0
        var deleteError: String?
        if r.system, !r.delete.isEmpty {
            phase = "Deleting the copies"
            do {
                try await PhotoKitDelete.delete(r.delete.map { ($0.uuid, $0.date) })
                deleted = r.delete.count
            } catch {
                deleteError = error.localizedDescription
            }
        }
        // Resolved groups leave the list; anything that failed stays to look at again.
        let done = Set(work.filter { !failedKeeps.contains($0.keep) }.map(\.id))
        if deleteError == nil {
            groups.removeAll { done.contains($0.id) }
            chosen.subtract(done)
        }
        var parts: [String] = []
        if deleted > 0 { parts.append("Deleted \(deleted) copies (in Recently Deleted for 30 days)") }
        if r.marked > 0 { parts.append("Put \(r.marked) copies in the album “\(r.album)” — delete them there in Photos") }
        if r.merged > 0 { parts.append("copied details onto \(r.merged) kept photos") }
        if let deleteError { parts.append("Nothing was deleted: \(deleteError)") }
        if !r.failed.isEmpty { parts.append("\(r.failed.count) groups left alone: \(r.failed.first!.reason)") }
        message = (parts.isEmpty ? "Nothing to do." : parts.joined(separator: "; ") + ".",
                   deleteError == nil && r.failed.isEmpty)
        state = .ready
    }

    /// For `--snapshot` renders only.
    func showForSnapshot(_ groups: [DupGroup], library: URL, system: Bool) {
        self.library = library
        self.groups = groups
        libraryName = library.deletingPathExtension().lastPathComponent
        isSystem = system
        chosen = Set(groups.filter(\.exact).map(\.id))
        state = .ready
    }
}
