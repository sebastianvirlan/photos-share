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
    /// years | months | all
    static var zoom: String? { env["PS_ZOOM"] }
    /// Opens the viewer on the Nth newest item (0 = newest).
    static var openItem: Int? { env["PS_OPEN"].flatMap(Int.init) }
    /// Saves the opened item to Photos straight away.
    static var save: Bool { env["PS_SAVE"] != nil }
    #else
    static let connect: (String, String?)? = nil
    static let openLibrary = false
    static let tab: String? = nil
    static let zoom: String? = nil
    static let openItem: Int? = nil
    static let save = false
    #endif
}
