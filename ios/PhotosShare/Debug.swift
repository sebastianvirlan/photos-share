import CoreGraphics
import Foundation

/// Debug builds only: launch settings that connect and navigate by themselves, so screens can be
/// checked in the simulator without tapping (`SIMCTL_CHILD_PS_CONNECT=… xcrun simctl launch …`).
enum DebugLaunch {
    #if DEBUG
    private static let env = ProcessInfo.processInfo.environment
    /// "address|password" (password optional)
    static var connect: (String, String?)? {
        guard let v = env["PS_CONNECT"] else { return nil }
        let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
    /// Opens the first library once per launch (not again after going back).
    static var openLibrary: Bool {
        guard env["PS_LIBRARY"] != nil, !openedLibrary else { return false }
        openedLibrary = true
        return true
    }
    nonisolated(unsafe) private static var openedLibrary = false
    static var tab: String? { env["PS_TAB"] }
    /// Opens the Hidden album from Albums.
    static var hidden: Bool { env["PS_HIDDEN"] != nil }
    /// years | months | all
    static var zoom: String? { env["PS_ZOOM"] }
    /// A pinch to apply to the grid: "scale,x,y" (x, y from 0 to 1 across the screen).
    static var pinch: (scale: CGFloat, x: CGFloat, y: CGFloat)? {
        guard let v = env["PS_PINCH"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 3 else { return nil }
        return (v[0], v[1], v[2])
    }
    /// Seconds between update checks (60 normally).
    static var pollSeconds: Double? { env["PS_POLL"].flatMap(Double.init) }
    /// e.g. "Videos"
    static var filter: String? { env["PS_FILTER"] }
    /// Opens the viewer on the Nth newest item (0 = newest).
    static var openItem: Int? { env["PS_OPEN"].flatMap(Int.init) }
    /// Saves the opened item to Photos straight away.
    static var save: Bool { env["PS_SAVE"] != nil }
    #else
    static let connect: (String, String?)? = nil
    static let openLibrary = false
    static let tab: String? = nil
    static let hidden = false
    static let zoom: String? = nil
    static let pinch: (scale: CGFloat, x: CGFloat, y: CGFloat)? = nil
    static let pollSeconds: Double? = nil
    static let filter: String? = nil
    static let openItem: Int? = nil
    static let save = false
    #endif
}
