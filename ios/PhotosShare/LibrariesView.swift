import SwiftUI

struct LibrariesView: View {
    @Environment(AppModel.self) private var app
    @State private var libraries: [LibrarySummary] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var path: [LibrarySummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let error, libraries.isEmpty {
                    ContentUnavailableView {
                        Label("Can’t reach the Mac", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if !loaded {
                    ProgressView()
                } else if libraries.isEmpty {
                    ContentUnavailableView("Nothing shared", systemImage: "photo.on.rectangle",
                                           description: Text("The Mac isn’t sharing any libraries."))
                } else {
                    List(libraries) { lib in
                        NavigationLink(value: lib) { LibraryRow(library: lib) }
                            .disabled(!lib.available && lib.state != "ready")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Libraries")
            .navigationDestination(for: LibrarySummary.self) { LibraryScreen(summary: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let a = app.address { Text(a) }
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { app.disconnect() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            libraries = try await api.libraries()
            error = nil
            if DebugLaunch.openLibrary, path.isEmpty, let first = libraries.first { path = [first] }
            if DebugLaunch.openLibrary, path.isEmpty, let first = libraries.first { path = [first] }
        } catch APIError.needsPassword {
            app.signedOut()
        } catch {
            self.error = ConnectView.describe(error)
        }
        loaded = true
    }
}

private struct LibraryRow: View {
    @Environment(AppModel.self) private var app
    let library: LibrarySummary

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover = library.cover, let api = app.api {
                    SquareImage(url: api.thumbURL(library.id, cover), maxPixels: 200)
                } else {
                    Image(systemName: "photo.stack").font(.title2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemFill))
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(library.name).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if !library.available && library.state != "ready" { return "Not available (drive unplugged?)" }
        guard let count = library.count else {
            return library.state == "error" ? "Couldn’t be opened" : "Opens when you tap it"
        }
        var parts = ["\(count.formatted()) items"]
        if let f = library.first.flatMap(Asset.parse), let l = library.last.flatMap(Asset.parse) {
            let y1 = Calendar.current.component(.year, from: f), y2 = Calendar.current.component(.year, from: l)
            parts.append(y1 == y2 ? "\(y1)" : "\(y1)–\(y2)")
        }
        return parts.joined(separator: " · ")
    }
}
