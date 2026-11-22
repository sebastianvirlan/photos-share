import AppKit
import SwiftUI

struct CleanupView: View {
    @Bindable var model: CleanupModel
    @State private var group: CleanupGroup = .matched
    @State private var comparing: CleanupRow?
    @State private var confirm: CleanupAction?

    var body: some View {
        VStack(spacing: 0) {
            pickers
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .sheet(item: $comparing) { row in CompareSheet(row: row, report: model.report, group: group) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil },
                                                                 set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let action = confirm {
                Button(confirmButton(action), role: action == .mark ? nil : .destructive) {
                    Task { await model.perform(action) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(confirmDetail)
        }
    }

    // MARK: - Choosing the two libraries

    private var pickers: some View {
        VStack(spacing: compact ? 12 : 16) {
            HStack(spacing: 18) {
                LibraryPicker(title: "Imported from", url: $model.source, compact: compact)
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                LibraryPicker(title: "Into", url: $model.dest, compact: compact)
            }
            Button {
                Task { await model.compare() }
            } label: {
                Label(model.report == nil ? "Compare" : "Compare Again",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(minWidth: 140)
            }
            .controlSize(compact ? .regular : .large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCompare)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 28)
        .animation(.snappy, value: compact)
    }

    /// Once there are results, the header shrinks so the photos get the space.
    private var compact: Bool {
        if case .idle = model.state { return false }
        if case .failed = model.state { return false }
        return true
    }

    // MARK: - Results

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            if let s = model.source, let d = model.dest {
                placeholder("Compare checks which photos from “\(s.deletingPathExtension().lastPathComponent)” are already in “\(d.deletingPathExtension().lastPathComponent)”, so you can safely remove them. Nothing changes until you choose an action.",
                            symbol: "checkmark.shield")
            } else {
                placeholder("Choose the library you imported from, and the one you imported into.",
                            symbol: "square.on.square")
            }
        case .comparing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Comparing the two libraries…").font(.headline)
                Text("Big libraries on a hard drive can take a minute.").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder(message, symbol: "exclamationmark.triangle")
        case .ready, .acting, .done:
            results
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(CleanupGroup.allCases) { g in
                    SummaryTile(group: g, count: model.rows(g).count, selected: group == g) { group = g }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            if let message = model.message {
                Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(message.ok ? .green : .red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 10)
            }

            Text(group.explanation + (model.rows(group).isEmpty ? "" : " Click a photo to compare both copies."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 3)], spacing: 3) {
                    ForEach(model.rows(group)) { row in
                        Button { comparing = row } label: {
                            Thumbnail(path: row.thumb)
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: group.symbol)
                                        .foregroundStyle(.white, color(group))
                                        .font(.system(size: 15)).padding(4)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(row.name ?? row.uuid)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            actionBar
        }
    }

    // MARK: - Actions

    @ViewBuilder private var actionBar: some View {
        let r = model.report
        let count = model.rows(.matched).count
        HStack(spacing: 10) {
            if case .acting(let action) = model.state {
                ProgressView().controlSize(.small)
                Text(action == .delete ? "Re-checking, then deleting…" : "Re-checking, then working…")
                Spacer()
            } else if case .done = model.state {
                Text("Done. Compare again to check the result.").foregroundStyle(.secondary)
                Spacer()
            } else if let r, count > 0 {
                Text(note(r)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Mark in Photos") { confirm = .mark }
                if r.source_is_system {
                    Button("Delete \(count) Photos", role: .destructive) { confirm = .delete }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else if r.all_verified {
                    Button("Move “\(r.source_name)” to Trash") { confirm = .trash }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Nothing in the source is verified in the destination, so there’s nothing to clean up.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func note(_ r: CleanupReport) -> String {
        if r.source_is_system {
            return "“\(r.source_name)” is your System Photo Library, so Photos Share can delete the verified photos directly."
        }
        if r.all_verified { return "Every photo in “\(r.source_name)” is in “\(r.dest_name)”." }
        return "Only the verified photos can go. To let Photos Share delete them directly, make “\(r.source_name)” the System Photo Library (Photos → Settings → General)."
    }

    private var confirmTitle: String {
        guard let action = confirm, let r = model.report else { return "" }
        let n = model.rows(.matched).count
        switch action {
        case .mark: return "Collect \(n) photos in an album?"
        case .delete: return "Delete \(n) photos from “\(r.source_name)”?"
        case .trash: return "Move the whole library “\(r.source_name)” to the Trash?"
        }
    }

    private var confirmDetail: String {
        guard let action = confirm, let r = model.report else { return "" }
        let n = model.rows(.matched).count
        switch action {
        case .mark:
            return "Photos will quit and reopen with “\(r.source_name)”, then an album “In \(r.dest_name) – safe to delete” is filled with exactly these \(n) photos. You review it and delete with ⌘A, ⌘⌫. Nothing is deleted by this step."
        case .delete:
            return "Both libraries are checked again first. Only the photos under “In the destination” are deleted, and macOS asks you to confirm too. They stay in Recently Deleted for 30 days."
        case .trash:
            return "Quit Photos first. Both libraries are checked again before anything moves. You can put the library back from the Trash until you empty it."
        }
    }

    private func confirmButton(_ a: CleanupAction) -> String {
        switch a {
        case .mark: "Mark in Photos"
        case .delete: "Delete Photos"
        case .trash: "Move to Trash"
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: 520)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func color(_ g: CleanupGroup) -> Color {
    switch g {
    case .matched: .green
    case .review: .purple
    case .editLost: .orange
    case .missing: .red
    }
}

struct SummaryTile: View {
    let group: CleanupGroup
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)").font(.system(size: 26, weight: .bold)).foregroundStyle(color(group))
                Text(group.title).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct LibraryPicker: View {
    let title: String
    @Binding var url: URL?
    var compact = false
    @State private var hovering = false

    private var name: String { url?.deletingPathExtension().lastPathComponent ?? "Choose a library…" }
    private var icon: some View {
        Image(systemName: url == nil ? "photo.badge.plus" : "photo.stack")
            .font(.system(size: compact ? 20 : 30))
            .foregroundStyle(url == nil ? Color.secondary : Color.accentColor)
    }
    private var caption: some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    var body: some View {
        Button(action: choose) {
            Group {
                if compact {
                    HStack(spacing: 10) {
                        icon
                        VStack(alignment: .leading, spacing: 1) {
                            caption
                            Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 230, height: 44)
                } else {
                    VStack(spacing: 8) {
                        icon
                        caption
                        Text(name).font(.headline)
                            .foregroundStyle(url == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(width: 220, height: 120)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.5))))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(url == nil ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.6),
                              style: StrokeStyle(lineWidth: 1.5, dash: url == nil ? [5, 4] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url?.path ?? "Choose the library you \(title.lowercased())")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the library you \(title.lowercased())."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if u.pathExtension == "photoslibrary" { url = u } else {
            let a = NSAlert()
            a.messageText = "Not a Photos library"
            a.informativeText = "“\(u.lastPathComponent)” isn’t a .photoslibrary."
            a.runModal()
        }
    }
}

struct CompareSheet: View {
    let row: CleanupRow
    let report: CleanupReport?
    let group: CleanupGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(row.name ?? row.uuid, systemImage: group.symbol).font(.headline)
                    .foregroundStyle(color(group))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(row.dest != nil ? "Matched by \(row.how ?? "fingerprint")." :
                    "No matching photo was found in the destination.")
                + Text(row.edited ? " This photo is edited in the source." : "")
            if let reason = row.reason {
                Label(reason, systemImage: "questionmark.circle.fill")
                    .foregroundStyle(.purple)
            }
            HStack(alignment: .top, spacing: 14) {
                side("Source · \(report?.source_name ?? "")", path: row.thumb,
                     caption: [row.name, formatted(row.date)])
                side("Destination · \(report?.dest_name ?? "")", path: row.dest_thumb,
                     caption: row.dest == nil ? ["Not in this library"] : [])
            }
        }
        .padding(18)
        .frame(width: 760)
    }

    private func side(_ title: String, path: String?, caption: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Thumbnail(path: path, maxPixels: 900, fill: false)
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(title).font(.subheadline.bold())
            ForEach(caption.compactMap { $0 }, id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formatted(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
