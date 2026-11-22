import AppKit
import Foundation
import Observation

enum AccessMode: String, CaseIterable, Identifiable {
    case local, tailscale, funnel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: "Only this Mac"
        case .tailscale: "Tailscale (private)"
        case .funnel: "Public link with password"
        }
    }
    var detail: String {
        switch self {
        case .local: "For trying it out. Nobody else can open it."
        case .tailscale: "Only devices on your Tailscale network. Viewers need the Tailscale app."
        case .funnel: "Anyone with the link reaches a password page. No app needed. Uses Tailscale Funnel."
        }
    }
}

/// Starts/stops `photos-share --machine` and mirrors its state. One per app.
@MainActor @Observable
final class ShareModel {
    static let shared = ShareModel()

    enum State: Equatable { case stopped, starting, running(url: String), failed(String) }

    private let defaults = UserDefaults.standard
    var path: String? { didSet { defaults.set(path, forKey: "path") } }
    var mode: AccessMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    var screenshots: Bool { didSet { defaults.set(screenshots, forKey: "screenshots") } }
    var hidden: Bool { didSet { defaults.set(hidden, forKey: "hidden") } }
    var downloads: Bool { didSet { defaults.set(downloads, forKey: "downloads") } }
    var convertVideo: Bool { didSet { defaults.set(convertVideo, forKey: "convertVideo") } }
    var requirePassword: Bool { didSet { defaults.set(requirePassword, forKey: "requirePassword") } }
    var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }

    private(set) var state: State = .stopped
    private(set) var log: [String] = []
    var hasPassword: Bool { Keychain.password()?.isEmpty == false }
    var isActive: Bool { state == .starting || isRunning }
    var isRunning: Bool { if case .running = state { true } else { false } }
    var url: String? { if case .running(let u) = state { u } else { nil } }
    var needsPassword: Bool { requirePassword || mode == .funnel }

    private var process: Process?
    private var buffer = ""

    private init() {
        path = defaults.string(forKey: "path")
        mode = AccessMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .tailscale
        screenshots = defaults.bool(forKey: "screenshots")
        hidden = defaults.bool(forKey: "hidden")
        downloads = defaults.bool(forKey: "downloads")
        convertVideo = defaults.bool(forKey: "convertVideo")
        requirePassword = defaults.bool(forKey: "requirePassword")
        keepAwake = defaults.object(forKey: "keepAwake") as? Bool ?? true
        port = defaults.object(forKey: "port") as? Int ?? 8080
    }

    func savePassword(_ value: String) { Keychain.setPassword(value) }

    func start() {
        guard !isActive, let path else { return }
        var args = [path, "--machine", "--port", String(port),
                    "--video", convertVideo ? "convert" : "original"]
        if screenshots { args.append("--screenshots") }
        if hidden { args.append("--hidden") }
        if downloads { args.append("--downloads") }
        if !keepAwake { args.append("--no-keep-awake") }
        switch mode {
        case .local: break
        case .tailscale: args.append("--tailscale")
        case .funnel: args.append("--funnel")
        }
        var env: [String: String] = [:]
        if needsPassword {
            guard let pw = Keychain.password(), !pw.isEmpty else {
                state = .failed("Set a password first.")
                return
            }
            if mode != .funnel { args.append("--password") }
            env["PHOTOS_SHARE_PASSWORD"] = pw
        }

        let p = Tools.process("photos-share", args, env: env)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.appendLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor in self?.ended(code) }
        }
        log = []
        state = .starting
        do {
            try p.run()
            process = p
        } catch {
            state = .failed("Couldn’t run photos-share: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.interrupt()  // SIGINT: the tool closes Funnel / keep-awake, then exits
    }

    /// For app quit: stop and wait briefly so a public link never outlives the app.
    nonisolated func stopAndWait() {
        MainActor.assumeIsolated {
            guard let p = process, p.isRunning else { return }
            p.interrupt()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate() }
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = obj["event"] as? String else { continue }
            switch event {
            case "ready": state = .running(url: obj["url"] as? String ?? "")
            case "error": state = .failed(obj["message"] as? String ?? "Unknown error")
            case "stopped": if case .failed = state {} else { state = .stopped }
            default: break
            }
        }
    }

    private func appendLog(_ text: String) {
        log.append(contentsOf: text.split(separator: "\n").map(String.init))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func ended(_ code: Int32) {
        process = nil
        switch state {
        case .failed: break
        case .running, .starting:
            state = code == 0 ? .stopped
                : .failed(log.last ?? "photos-share stopped unexpectedly (code \(code)).")
        case .stopped: break
        }
    }

    func copyLink() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func openLink() {
        if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
