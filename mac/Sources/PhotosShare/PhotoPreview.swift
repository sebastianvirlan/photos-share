import AVKit
import SwiftUI

/// Large view of one photo from the Import grid (double-click). ← → to move through the
/// photos shown, Space to select or deselect, Esc to close.
struct PhotoPreview: View {
    @Bindable var model: ImportModel
    @State var uuid: String
    @Environment(\.dismiss) private var dismiss

    private var items: [ImportItem] { model.visible }
    private var index: Int? { items.firstIndex { $0.uuid == uuid } }
    private var item: ImportItem? { index.map { items[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                media(item).id(item.uuid)
                Divider()
                bar(item)
            } else {
                Text("This photo isn’t shown any more.").frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).padding()
            }
        }
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 620, idealHeight: 820)
    }

    @ViewBuilder private func media(_ item: ImportItem) -> some View {
        ZStack {
            Color.black
            if item.movie, let path = item.original {
                VideoPlayer(player: AVPlayer(url: URL(fileURLWithPath: path)))
            } else {
                // The small preview straight away, the full photo over it once loaded.
                Thumbnail(path: item.thumb, maxPixels: 640, fill: false, background: false)
                if let path = item.original {
                    Thumbnail(path: path, maxPixels: 2400, fill: false, background: false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bar(_ item: ImportItem) -> some View {
        let selected = model.selection.contains(item.uuid)
        return HStack(spacing: 12) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled((index ?? 0) == 0)
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled((index ?? 0) >= items.count - 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? item.uuid).font(.headline).textSelection(.enabled)
                Text(details(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let i = index { Text("\(i + 1) of \(items.count)").foregroundStyle(.secondary) }
            Button {
                model.toggle(item)
            } label: {
                Label(selected ? "Selected" : "Select", systemImage: selected ? "checkmark.circle.fill" : "circle")
                    .frame(minWidth: 90)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(selected ? .accentColor : .gray)
            .help("Space")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func details(_ item: ImportItem) -> String {
        var parts = [String(item.date.prefix(16)).replacingOccurrences(of: "T", with: " ")]
        if item.movie { parts.append("Video") }
        if item.live { parts.append("Live Photo") }
        if item.edited { parts.append("Edited") }
        if item.favorite { parts.append("♥ Favourite") }
        if item.hidden { parts.append("Hidden") }
        if item.in_dest { parts.append("Already in “\(model.plan?.dest_name ?? "")”") }
        if !item.albums.isEmpty { parts.append("Albums: " + item.albums.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private func move(_ step: Int) {
        guard let i = index, items.indices.contains(i + step) else { return }
        uuid = items[i + step].uuid
    }
}
