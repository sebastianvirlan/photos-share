import AppKit
import SwiftUI

struct ImportView: View {
    @Bindable var model: ImportModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 600)
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
                filters
                grid
                Divider()
                bottomBar
            }
        case .importing:
            progress
        case .done:
            result
        }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 3)], spacing: 3) {
                        ForEach(items) { item in
                            ImportTile(item: item, selected: model.selection.contains(item.uuid),
                                       destName: model.plan?.dest_name ?? "")
                                .onTapGesture { model.toggle(item) }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selection.count) selected").font(.headline)
                Text("\(model.visible.count) shown · \(model.alreadyInDest) already in “\(model.plan?.dest_name ?? "")”")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Select All") { model.selectVisible() }
            Button("Select None") { model.deselectVisible() }
            Spacer()
            if model.selectedEdited > 0 {
                Picker("\(model.selectedEdited) edited:", selection: $model.editedMode) {
                    ForEach(EditedMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 330)
                .help(model.editedMode.detail)
            }
            Button {
                confirming = true
            } label: {
                Label("Import \(importCount) Photos", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(importCount == 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var importCount: Int {
        model.editedMode == .skip ? model.selection.count - model.selectedEdited : model.selection.count
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(model.done), total: Double(max(model.total, 1)))
                .frame(width: 380)
            Text("\(model.phase)… \(model.done) of \(model.total)").font(.headline)
            Text("Photos is adding them to “\(model.plan?.dest_name ?? "")”. Photos already added stay if you cancel.")
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { model.cancel() }
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var result: some View {
        let s = model.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Imported \(s?.imported ?? 0) of \(s?.requested ?? 0) into “\(model.plan?.dest_name ?? "")”",
                      systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.green)
                if let skipped = s?.skipped_edited, !skipped.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("To keep their edits editable, bring these across with Photos’ own File → Import (choose “\(model.plan?.source_name ?? "")”). Only these need it.")
                                .foregroundStyle(.secondary)
                            Text(skipped.compactMap(\.name).joined(separator: ", "))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("\(skipped.count) edited photos skipped", systemImage: "pencil.circle")
                    }
                }
                if let failed = s?.failed, !failed.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(failed, id: \.self) { f in
                                Text("\(f.name ?? f.uuid): \(f.reason)").font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("\(failed.count) problems", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button {
                        let c = CleanupModel.shared
                        c.prepare(source: model.source, dest: model.dest)
                        openWindow(id: "cleanup")
                        NSApp.activate(ignoringOtherApps: true)
                        Task { await c.compare() }
                    } label: {
                        Label("Open Clean Up", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Check what arrived, then optionally remove it from “\(model.plan?.source_name ?? "")”.")
                    Button("Import More") { Task { await model.load() } }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private var confirmTitle: String {
        "Import \(importCount) photos into “\(model.plan?.dest_name ?? "")”?"
    }

    private var confirmMessage: String {
        var text = "Photos will quit and reopen with “\(model.plan?.dest_name ?? "")”, then add the photos in batches. Nothing is removed from “\(model.plan?.source_name ?? "")”."
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

struct ImportTile: View {
    let item: ImportItem
    let selected: Bool
    let destName: String

    var body: some View {
        Thumbnail(path: item.thumb)
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
                HStack(spacing: 4) {
                    if item.movie { Image(systemName: "play.fill") }
                    if item.live { Text("LIVE").font(.system(size: 8, weight: .bold)) }
                    if item.favorite { Image(systemName: "heart.fill") }
                    if item.edited { Image(systemName: "pencil.circle.fill") }
                    if item.hidden { Image(systemName: "eye.slash.fill") }
                }
                .font(.system(size: 10)).foregroundStyle(.white).shadow(radius: 1.5).padding(5)
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
