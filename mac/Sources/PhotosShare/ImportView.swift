import AppKit
import SwiftUI

struct ImportView: View {
    @Bindable var model: ImportModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirming = false
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var marqueeBox: CGRect?
    @State private var marqueeBase: Set<String>?
    @State private var marqueeMode: ImportModel.MarqueeMode = .replace
    @State private var previewing: PreviewTarget?
    @State private var showingDetails = false
    @AppStorage("gridTileSize") private var tileSize = 110.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 600)
        .sheet(item: $previewing) { PhotoPreview(model: model, uuid: $0.id) }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Import") { model.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - Libraries

    private var compact: Bool {
        switch model.state {
        case .idle, .failed: false
        default: true
        }
    }

    private var header: some View {
        VStack(spacing: compact ? 12 : 16) {
            HStack(spacing: 18) {
                LibraryPicker(title: "Import from", url: $model.source, compact: compact)
                Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                LibraryPicker(title: "Into", url: $model.dest, compact: compact)
            }
            HStack(spacing: 14) {
                Button {
                    Task { await model.load() }
                } label: {
                    Label(model.plan == nil ? "Show Photos" : "Reload", systemImage: "photo.on.rectangle.angled")
                        .frame(minWidth: 140)
                }
                .controlSize(compact ? .regular : .large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canLoad)
                Toggle("Include hidden photos", isOn: $model.includeHidden)
                    .toggleStyle(.checkbox)
                    .disabled(!model.canLoad)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 28)
        .animation(.snappy, value: compact)
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            note(model.source != nil && model.dest != nil
                 ? "Show Photos lists everything in “\(name(model.source))”, with what’s already in “\(name(model.dest))” left out, so nothing is imported twice."
                 : "Choose the library to import from, and the one to import into.",
                 symbol: "square.and.arrow.down.on.square")
        case .loading:
            busy("Reading both libraries…", "Big libraries on a hard drive can take a minute.")
        case .failed(let message):
            note(message, symbol: "exclamationmark.triangle")
        case .ready:
            VStack(spacing: 0) {
                editsStatus
                filters
                grid
                Divider()
                resultStrip
                bottomBar
            }
        }
    }

    /// Whether edits will arrive editable, and how to make them if not.
    @ViewBuilder private var editsStatus: some View {
        let dest = model.plan?.dest_name ?? ""
        Group {
            if model.keepsEdits {
                Label("Edits stay editable: “\(dest)” is the System Photo Library.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label {
                    Text("Edited photos can’t keep their edits, because “\(dest)” isn’t the System Photo Library. To keep them, open “\(dest)” in Photos, choose Photos → Settings → General → Use as System Photo Library, then click Reload.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 12)
    }

    private var filters: some View {
        HStack(spacing: 14) {
            Toggle("New only", isOn: $model.onlyNew)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
                .help("Hide photos that are already in “\(model.plan?.dest_name ?? "")”")
            Picker("Album", selection: $model.album) {
                Text("All albums").tag(String?.none)
                ForEach(model.plan?.albums ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 200)
            Picker("Year", selection: $model.year) {
                Text("All years").tag(String?.none)
                ForEach(model.years, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 150)
            Picker("Show", selection: $model.media) {
                ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Toggle("♥ Favourites", isOn: $model.favoritesOnly).toggleStyle(.button)
            Spacer()
            ZoomControl(size: $tileSize)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var grid: some View {
        let items = model.visible
        return Group {
            if items.isEmpty {
                note(model.onlyNew && (model.plan?.items.isEmpty == false)
                     ? "Everything matching these filters is already in “\(model.plan?.dest_name ?? "")”."
                     : "No photos match these filters.", symbol: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize), spacing: 3)], spacing: 3) {
                        ForEach(items) { item in
                            ImportTile(item: item, selected: model.selection.contains(item.uuid),
                                       destName: model.plan?.dest_name ?? "",
                                       maxPixels: ZoomControl.pixels(for: tileSize))
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: TileFrames.self,
                                                           value: [item.uuid: g.frame(in: .named("grid"))])
                                })
                                .onTapGesture {
                                    model.click(item, extendingRange: NSEvent.modifierFlags.contains(.shift))
                                }
                                // Both clicks of a double-click toggle (cancelling out), so single
                                // clicks stay instant; the double-click then opens the photo.
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    previewing = PreviewTarget(id: item.uuid)
                                })
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                    .contentShape(Rectangle())  // drags can start in the gaps too
                    .coordinateSpace(name: "grid")
                    .onPreferenceChange(TileFrames.self) { tileFrames = $0 }
                    .simultaneousGesture(marqueeDrag)  // also when the drag starts on a tile
                    .overlay(alignment: .topLeading) {
                        if let box = marqueeBox {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.15))
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                                .frame(width: box.width, height: box.height)
                                .offset(x: box.minX, y: box.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .help("Click to select or deselect, double-click to open. Shift-click selects a range. Drag a box to select; hold Shift or ⌘ to add, Option to remove.")
            }
        }
    }

    /// Dragging a box selects the photos it touches (Shift/⌘: add to the selection, Option: remove).
    private var marqueeDrag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { v in
                if marqueeBase == nil {
                    marqueeBase = model.selection
                    let flags = NSEvent.modifierFlags
                    marqueeMode = flags.contains(.option) ? .remove
                        : (flags.contains(.shift) || flags.contains(.command)) ? .add : .replace
                }
                let box = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                 width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                marqueeBox = box
                let touched = Set(tileFrames.filter { $0.value.intersects(box) }.keys)
                model.marquee(base: marqueeBase ?? [], touched: touched, mode: marqueeMode)
            }
            .onEnded { _ in
                marqueeBox = nil
                marqueeBase = nil
            }
    }

    /// While importing: progress and Cancel. Otherwise: selection and the Import button.
    @ViewBuilder private var bottomBar: some View {
        if model.isImporting {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.phase)… \(model.done) of \(model.total)").font(.headline)
                    ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
                        .frame(maxWidth: 360)
                }
                Text("You can keep browsing and selecting meanwhile.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .help("Stops after the current batch. Photos already added stay in “\(model.plan?.dest_name ?? "")”.")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.selection.count) selected").font(.headline)
                    Text("\(model.visible.count) shown · \(model.alreadyInDest) already in “\(model.plan?.dest_name ?? "")”")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Select All") { model.selectVisible() }
                Button("Select None") { model.deselectVisible() }
                Spacer()
                if model.selectedEdited > 0 && !model.keepsEdits {
                    Picker("\(model.selectedEdited) edited:", selection: $model.editedMode) {
                        ForEach(EditedMode.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 330)
                    .help(model.editedMode.detail)
                }
                Button {
                    confirming = true
                } label: {
                    Label("Import \(model.importCount) Photos", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.importCount == 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
    }

    /// The last import's outcome, above the bottom bar; details in a popover.
    @ViewBuilder private var resultStrip: some View {
        if !model.isImporting, model.summary != nil || model.importError != nil {
            let s = model.summary
            let problems = (s?.failed.count ?? 0) + (s?.skipped_edited.count ?? 0)
            HStack(spacing: 12) {
                if let error = model.importError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                } else if let s {
                    Label("\(s.cancelled == true ? "Cancelled: imported" : "Imported") \(s.imported) of \(s.requested) into “\(model.plan?.dest_name ?? "")”"
                          + (problems > 0 ? " · \(problems) to look at" : ""),
                          systemImage: problems > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(problems > 0 ? .orange : .green)
                }
                Spacer()
                if !model.notImported.isEmpty {
                    Button("Select \(model.notImported.count) Not Imported") { model.selectNotImported() }
                        .help("Select the photos from this import that didn’t arrive, to look at them or try again.")
                }
                if problems > 0 {
                    Button("Details") { showingDetails = true }
                        .popover(isPresented: $showingDetails, arrowEdge: .top) { resultDetails.frame(width: 520) }
                }
                if (s?.imported ?? 0) > 0 {
                    Button {
                        let c = CleanupModel.shared
                        c.prepare(source: model.source, dest: model.dest)
                        openWindow(id: "cleanup")
                        NSApp.activate(ignoringOtherApps: true)
                        Task { await c.compare() }
                    } label: {
                        Label("Open Clean Up", systemImage: "checkmark.shield")
                    }
                    .help("Check what arrived, then optionally remove it from “\(model.plan?.source_name ?? "")”.")
                }
                Button { model.dismissResult() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(.quaternary.opacity(0.5))
        }
    }

    private var resultDetails: some View {
        let s = model.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let skipped = s?.skipped_edited, !skipped.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(skipped.count) edited photos skipped", systemImage: "pencil.circle").font(.headline)
                        Text("To bring these across with their edits still editable, make “\(model.plan?.dest_name ?? "")” the System Photo Library (Photos → Settings → General), then import them again here.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(skipped.compactMap(\.name).joined(separator: ", "))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if let failed = s?.failed, !failed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(failed.count) problems", systemImage: "exclamationmark.triangle")
                            .font(.headline).foregroundStyle(.orange)
                        ForEach(failed, id: \.self) { f in
                            Text("\(f.name ?? f.uuid): \(f.reason)").font(.caption).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }

    // MARK: - Helpers

    private var confirmTitle: String {
        "Import \(model.importCount) photos into “\(model.plan?.dest_name ?? "")”?"
    }

    private var confirmMessage: String {
        let dest = model.plan?.dest_name ?? "", src = model.plan?.source_name ?? ""
        if model.keepsEdits {
            return "They’re added straight to “\(dest)” with their edits (still editable), Live Photos, favourites, dates, places and albums. If any have titles, captions or keywords, Photos opens at the end to add those. Nothing is removed from “\(src)”."
        }
        var text = "Photos will quit and reopen with “\(dest)”, then add the photos in batches. Nothing is removed from “\(src)”."
        if model.selectedEdited > 0 {
            text += "\n\n\(model.selectedEdited) edited: \(model.editedMode.title.lowercased()). \(model.editedMode.detail)"
        }
        return text
    }

    private func name(_ url: URL?) -> String { url?.deletingPathExtension().lastPathComponent ?? "" }

    private func note(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 520).textSelection(.enabled)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func busy(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where each tile is in the grid, for selecting by dragging a box.
private struct TileFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct PreviewTarget: Identifiable { let id: String }

struct ImportTile: View {
    let item: ImportItem
    let selected: Bool
    let destName: String
    var maxPixels = 320

    var body: some View {
        Thumbnail(path: item.thumb, maxPixels: maxPixels)
            .aspectRatio(1, contentMode: .fit)
            .opacity(item.in_dest ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.9),
                                     selected ? Color.accentColor : Color.black.opacity(0.25))
                    .shadow(radius: 1).padding(5)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    if item.movie { Image(systemName: "play.fill").help("Video") }
                    if item.live { Text("LIVE").font(.system(size: 9, weight: .bold)).help("Live Photo") }
                    if item.favorite { Image(systemName: "heart.fill").help("Favourite") }
                    if item.edited { Image(systemName: "pencil").help("Edited in Photos") }
                    if item.hidden { Image(systemName: "eye.slash.fill").help("Hidden") }
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2).padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.in_dest {
                    Text("In \(destName)").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule()).padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            .contentShape(Rectangle())
            .help(item.name ?? item.uuid)
    }
}
