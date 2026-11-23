import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @State private var confirming = false
    @State private var previewing: PreviewTarget?
    @AppStorage("dupTileSize") private var tileSize = 150.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 600)
        .sheet(item: $previewing) { target in
            if let group = model.groups.first(where: { g in g.copies.contains { $0.uuid == target.id } }) {
                DuplicatePreview(group: group, uuid: target.id)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(model.isSystem ? "Delete \(model.copiesToRemove) Copies" : "Put Them in an Album",
                   role: model.isSystem ? .destructive : nil) { model.resolve() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - Header

    private var compact: Bool {
        switch model.state {
        case .idle, .failed: false
        default: true
        }
    }

    private var header: some View {
        VStack(spacing: compact ? 12 : 16) {
            LibraryPicker(title: "Library", url: $model.library, compact: compact)
                .frame(maxWidth: 460)
            HStack(spacing: 14) {
                Button {
                    model.scan()
                } label: {
                    Label(model.groups.isEmpty && model.state != .ready ? "Find Duplicates" : "Scan Again",
                          systemImage: "square.on.square.dashed")
                        .frame(minWidth: 150)
                }
                .controlSize(compact ? .regular : .large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canScan)
                Toggle("Include hidden photos", isOn: $model.includeHidden)
                    .toggleStyle(.checkbox)
                    .disabled(!model.canScan)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 28)
        .animation(.snappy, value: compact)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            note(model.library == nil
                 ? "Choose a library to look for duplicates in."
                 : "Finds photos that are in “\(model.library!.deletingPathExtension().lastPathComponent)” more than once: exact copies of the same file, and the same picture saved again (resized, recompressed, re-exported). Nothing changes until you choose what to keep.",
                 symbol: "square.on.square.dashed")
        case .scanning:
            VStack(spacing: 12) {
                if model.total > 0 {
                    ProgressView(value: Double(model.done), total: Double(model.total)).frame(width: 380)
                    Text("\(model.phase)… \(model.done.formatted()) of \(model.total.formatted())").font(.headline)
                } else {
                    ProgressView()
                    Text("\(model.phase)…").font(.headline)
                }
                Text("The first scan of a big library takes a few minutes; later scans are quick.")
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            note(message, symbol: "exclamationmark.triangle")
        case .ready, .working:
            VStack(spacing: 0) {
                summary
                if model.groups.isEmpty {
                    note("No duplicates in “\(model.libraryName)”.", symbol: "checkmark.circle")
                } else {
                    list
                }
                if let m = model.message {
                    Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(m.ok ? .green : .orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5))
                }
                Divider()
                bottomBar
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Text("\(model.exactCount) groups of exact copies · \(model.nearCount) that look alike")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Picker("Show", selection: $model.filter) {
                ForEach(DupFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 280)
            ZoomControl(size: $tileSize)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.shown) { group in
                    GroupCard(group: group, chosen: model.chosen.contains(group.id), tileSize: tileSize,
                              onChoose: { model.toggle(group) },
                              onKeep: { model.setKeep($0, in: group) },
                              onOpen: { previewing = PreviewTarget(id: $0.uuid) })
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .disabled(model.state == .working)
    }

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 12) {
            if model.state == .working {
                ProgressView().controlSize(.small)
                Text("\(model.phase)…").font(.headline)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.chosenGroups.count) groups · \(model.copiesToRemove) copies to remove").font(.headline)
                    Text(model.isSystem
                         ? "Kept photos get the others’ favourite, albums, keywords, caption and place first."
                         : "“\(model.libraryName)” isn’t the System Photo Library, so copies go into the album “Duplicates to delete” (details are merged first).")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Select All Exact") { model.chooseAllExact() }
                Button("Select Shown") { model.chooseShown() }
                Button("Select None") { model.chooseNone() }
                Button {
                    confirming = true
                } label: {
                    Label(model.isSystem ? "Delete \(model.copiesToRemove) Copies"
                                         : "Mark \(model.copiesToRemove) Copies",
                          systemImage: model.isSystem ? "trash" : "rectangle.stack.badge.plus")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(model.isSystem ? .red : .accentColor)
                .disabled(model.copiesToRemove == 0)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: - Helpers

    private var confirmTitle: String {
        model.isSystem
            ? "Delete \(model.copiesToRemove) copies from “\(model.libraryName)”?"
            : "Put \(model.copiesToRemove) copies in the album “Duplicates to delete”?"
    }

    private var confirmMessage: String {
        let near = model.chosenGroups.filter { !$0.exact }.count
        var text = "One photo of each of the \(model.chosenGroups.count) groups is kept (the one marked Keep). It first gets the others’ favourite, albums, keywords, title, caption and place, so nothing is lost. Photos opens briefly if any of that is needed."
        text += model.isSystem
            ? " The copies then go to Recently Deleted, where they stay for 30 days."
            : " The copies are then put in an album for you to delete in Photos."
        if near > 0 { text += "\n\n\(near) of the groups are look-alikes, not exact copies: make sure you checked them." }
        return text
    }

    private func note(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 520).textSelection(.enabled)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One group of duplicates: tick it to resolve it, click a copy to keep that one instead.
struct GroupCard: View {
    let group: DupGroup
    let chosen: Bool
    let tileSize: Double
    let onChoose: () -> Void
    let onKeep: (DupCopy) -> Void
    let onOpen: (DupCopy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { chosen }, set: { _ in onChoose() })) {
                    Text(group.exact ? "Exact copies" : "Look alike").font(.headline)
                }
                .toggleStyle(.checkbox)
                Text(group.exact ? "Same file, \(group.copies.count) times"
                                 : "The same picture saved again? Check before removing.")
                    .font(.caption).foregroundStyle(group.exact ? Color.secondary : Color.orange)
                Spacer()
                Text("Click a photo to keep it instead · double-click to open")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(group.copies) { c in
                        CopyTile(copy: c, keep: c.uuid == group.keep, removing: chosen && c.uuid != group.keep,
                                 exact: group.exact, size: tileSize)
                            .onTapGesture { onKeep(c) }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(c) })
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(chosen ? 0.7 : 0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(chosen ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
    }
}

struct CopyTile: View {
    let copy: DupCopy
    let keep: Bool
    let removing: Bool
    let exact: Bool
    let size: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Thumbnail(path: copy.thumb, maxPixels: ZoomControl.pixels(for: size))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(removing ? 0.55 : 1)
                .overlay(alignment: .topLeading) {
                    if keep {
                        tag("Keep", "checkmark.circle.fill", .green)
                    } else if removing {
                        tag("Remove", "trash.fill", .red)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        if copy.movie { Image(systemName: "play.fill").help("Video") }
                        if copy.live { Text("LIVE").font(.system(size: 9, weight: .bold)).help("Live Photo") }
                        if copy.favorite { Image(systemName: "heart.fill").help("Favourite") }
                        if copy.edited { Image(systemName: "pencil").help("Edited in Photos") }
                        if copy.hidden { Image(systemName: "eye.slash.fill").help("Hidden") }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2).padding(6)
                }
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(keep ? Color.green : .clear, lineWidth: 3))
            Text(copy.name ?? copy.uuid).font(.caption.weight(.medium)).lineLimit(1)
            Text("\(String(copy.width))×\(String(copy.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(copy.size), countStyle: .file))")
                .font(.caption2).foregroundStyle(.secondary)
            Text(String(copy.date.prefix(16)).replacingOccurrences(of: "T", with: " "))
                .font(.caption2).foregroundStyle(.secondary)
            if !copy.albums.isEmpty {
                Text(copy.albums.count == 1 ? "In “\(copy.albums[0])”" : "In \(copy.albums.count) albums")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if !exact && !keep {
                Text(copy.distance <= 2 ? "Looks identical" : "Looks very similar")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
        .help((copy.name ?? "") + (copy.albums.isEmpty ? "" : "\nAlbums: " + copy.albums.joined(separator: ", ")))
    }

    private func tag(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
            .padding(5)
    }
}

/// Large view of the copies in one group, ← → to compare them.
struct DuplicatePreview: View {
    let group: DupGroup
    @State var uuid: String
    @Environment(\.dismiss) private var dismiss

    private var index: Int { group.copies.firstIndex { $0.uuid == uuid } ?? 0 }
    private var copy: DupCopy { group.copies[index] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if copy.movie, let path = copy.original {
                    VideoView(url: URL(fileURLWithPath: path))
                } else {
                    Thumbnail(path: copy.thumb, maxPixels: 640, fill: false, background: false)
                    if let path = copy.original {
                        Thumbnail(path: path, maxPixels: 2400, fill: false, background: false)
                    }
                }
            }
            .id(copy.uuid)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Button { uuid = group.copies[max(0, index - 1)].uuid } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0)
                Button { uuid = group.copies[min(group.copies.count - 1, index + 1)].uuid } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).disabled(index == group.copies.count - 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text((copy.name ?? copy.uuid) + (copy.uuid == group.keep ? "  ·  Keep" : ""))
                        .font(.headline).textSelection(.enabled)
                    Text("\(String(copy.width))×\(String(copy.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(copy.size), countStyle: .file)) · taken \(String(copy.date.prefix(16)).replacingOccurrences(of: "T", with: " ")) · added \(String(copy.added.prefix(10)))"
                         + (copy.albums.isEmpty ? "" : " · " + copy.albums.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(index + 1) of \(group.copies.count)").foregroundStyle(.secondary)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 620, idealHeight: 820)
    }
}
