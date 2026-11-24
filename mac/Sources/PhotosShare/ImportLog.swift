import Foundation

/// A plain-text record of each import (what was asked, which route, what Photos and the tools
/// answered), in ~/Library/Logs/Photos Share/import.log, to see afterwards what happened.
enum ImportLog {
    static let file: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Photos Share/import.log")

    static func write(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withFullTime])
        let line = Data("\(stamp)  \(text)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep it small: start again past 5 MB.
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: file)
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: file)
        }
    }

    /// A tool's output line, unless it's just progress.
    static func tool(_ line: String) {
        if !line.contains("\"event\": \"progress\"") { write("  photos-import: \(line)") }
    }
}
