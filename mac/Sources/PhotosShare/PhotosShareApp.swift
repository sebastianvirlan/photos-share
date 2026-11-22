import AppKit
import SwiftUI

@main
struct PhotosShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var share = ShareModel.shared
    @State private var cleanup = CleanupModel.shared
    @State private var importer = ImportModel.shared

    init() {
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(share: share)
        } label: {
            Image(systemName: share.isRunning ? "photo.fill.on.rectangle.fill" : "photo.on.rectangle")
        }

        Window("Sharing", id: "share") {
            ShareView(model: share)
        }
        .windowResizability(.contentSize)

        Window("Import Between Libraries", id: "import") {
            ImportView(model: importer)
        }

        Window("Clean Up After Import", id: "cleanup") {
            CleanupView(model: cleanup)
        }
    }
}

struct MenuContent: View {
    let share: ShareModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch share.state {
        case .running(let url): Text("Sharing: \(url)")
        case .starting: Text("Starting…")
        case .failed(let m): Text("Error: \(m)")
        case .stopped: Text("Not sharing")
        }
        Divider()
        Button("Sharing…") { show("share") }
        if share.isActive {
            Button("Stop Sharing") { share.stop() }
            Button("Copy Link") { share.copyLink() }.disabled(!share.isRunning)
            Button("Open in Browser") { share.openLink() }.disabled(!share.isRunning)
        } else {
            Button("Start Sharing") { share.start() }
                .disabled(share.path == nil || (share.needsPassword && !share.hasPassword))
        }
        Divider()
        Button("Import Between Libraries…") { show("import") }
        Button("Clean Up After Import…") { show("cleanup") }
        Divider()
        Button("Quit Photos Share") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)  // menu bar apps don't come forward on their own
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let manifest = EditSpike.requested {
            Task { @MainActor in await EditSpike.run(manifest) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ShareModel.shared.stopAndWait()  // never leave a public link or keep-awake behind
    }
}
