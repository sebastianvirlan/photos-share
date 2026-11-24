import AppKit
import SwiftUI

@main
struct PhotosShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var share = ShareModel.shared
    @State private var cleanup = CleanupModel.shared
    @State private var importer = ImportModel.shared
    @State private var duplicates = DuplicatesModel.shared

    init() {
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    @State private var nav = AppNavigation.shared

    var body: some Scene {
        Window("Photos Share", id: "main") {
            MainView(nav: nav, share: share, importer: importer, cleanup: cleanup, duplicates: duplicates)
        }
        .commands {
            CommandMenu("Tools") {
                ForEach(Array(Tool.allCases.enumerated()), id: \.element) { i, tool in
                    Button(tool.title) { nav.tool = tool }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let manifest = EditSpike.requested {
            Task { @MainActor in await EditSpike.run(manifest) }
        } else if let manifest = CreateSpike.requested {
            Task { @MainActor in await CreateSpike.run(manifest) }
        } else if let dir = ProcessInfo.processInfo.environment["PS_WINDOW_SNAPSHOT"] {
            Task { @MainActor in await WindowSnapshot.run(into: dir) }
        }
    }

    /// Closing the window keeps the app (and sharing) running; the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting stops whatever is running: say what, and let you change your mind.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var running: [String] = []
        if ImportModel.shared.isImporting { running.append("an import (photos already created stay; the rest can be finished later)") }
        if case .acting = CleanupModel.shared.state { running.append("a clean-up") }
        if DuplicatesModel.shared.state == .working { running.append("merging duplicates") }
        if ShareModel.shared.isActive { running.append("sharing (the link stops working)") }
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Photos Share?"
        alert.informativeText = "This stops " + running.joined(separator: ", and ") + "."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShareModel.shared.stopAndWait()  // never leave a public link or keep-awake behind
    }
}


/// Debug: `PS_WINDOW_SNAPSHOT=dir PhotosShare` saves the real window for each tool, then quits
/// (ImageRenderer can't draw the sidebar or AppKit controls; the window itself can).
@MainActor
enum WindowSnapshot {
    static func run(into dir: String) async {
        try? await Task.sleep(for: .seconds(2))
        // Clean Up with sample results, so its action bar shows (nothing is saved).
        CleanupModel.shared.showForSnapshot(Snapshot.sample,
                                            source: URL(fileURLWithPath: "/Volumes/HDD/iPhone 13 Backup.photoslibrary"),
                                            dest: URL(fileURLWithPath: "/Volumes/HDD/Trips.photoslibrary"))
        for tool in Tool.allCases {
            AppNavigation.shared.tool = tool
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { continue }
            // The real window as on screen (needs Screen Recording permission for the caller).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/window-\(tool.rawValue).png"]
            try? p.run()
            p.waitUntilExit()
        }
        NSApp.terminate(nil)
    }
}
