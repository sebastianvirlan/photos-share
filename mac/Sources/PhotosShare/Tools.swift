import Foundation
import Security

/// Runs the Python tools (`photos-share`, `photos-dedupe`) from the repo checkout via uv.
/// The build script records both paths in Info.plist; env vars override them for `swift run`.
enum Tools {
    static var uv: String {
        ProcessInfo.processInfo.environment["PS_UV"]
            ?? Bundle.main.object(forInfoDictionaryKey: "PSUVPath") as? String
            ?? "/opt/homebrew/bin/uv"
    }

    static var repo: String {
        ProcessInfo.processInfo.environment["PS_REPO"]
            ?? Bundle.main.object(forInfoDictionaryKey: "PSRepoPath") as? String
            ?? FileManager.default.currentDirectoryPath
    }

    static func process(_ tool: String, _ args: [String], env: [String: String] = [:]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--project", repo, "--quiet", tool] + args
        var environment = ProcessInfo.processInfo.environment
        environment.merge(env) { $1 }
        p.environment = environment
        return p
    }

    /// Runs a tool to completion off the main thread; returns (exit code, stdout, stderr).
    static func run(_ tool: String, _ args: [String]) async throws -> (Int32, Data, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = process(tool, args)
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let outBuf = Buffer(), errBuf = Buffer()
            out.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (proc.terminationStatus, outBuf.data,
                                        String(decoding: errBuf.data, as: UTF8.self)))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// Thread-safe byte buffer for pipe output.
final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// The viewer password, in the login Keychain (same item the command line uses).
enum Keychain {
    private static let service = "photos-share", account = "viewers"

    static func password() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        if SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
