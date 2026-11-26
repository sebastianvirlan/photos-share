import LocalAuthentication
import SwiftUI

/// The Hidden album, locked behind Face ID (or the iPhone passcode) as in Photos. Unlocking
/// lasts until the app goes to the background.
struct HiddenAlbum: View {
    @Environment(AppModel.self) private var app
    let model: LibraryModel
    @State private var failed: String?
    @State private var asking = false

    var body: some View {
        Group {
            if app.hiddenUnlocked {
                PhotoGrid(libraryID: model.id, assets: model.hidden,
                          downloads: model.detail?.downloads ?? false)
            } else {
                ContentUnavailableView {
                    Label("Hidden Album Is Locked", systemImage: "lock.fill")
                } description: {
                    Text(failed ?? "Use Face ID to view this album.")
                } actions: {
                    Button("View Album") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(asking)
                }
            }
        }
        .navigationTitle("Hidden")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !app.hiddenUnlocked { await unlock() } }
    }

    private func unlock() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let context = LAContext()
        do {
            // Face ID, falling back to the passcode, like Photos.
            if try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                localizedReason: "View the Hidden album") {
                app.hiddenUnlocked = true
                failed = nil
            }
        } catch LAError.passcodeNotSet {
            failed = "Set a passcode for this iPhone in Settings to view the Hidden album."
        } catch LAError.userCancel, LAError.appCancel, LAError.systemCancel {
            failed = nil
        } catch {
            failed = error.localizedDescription
        }
    }
}
