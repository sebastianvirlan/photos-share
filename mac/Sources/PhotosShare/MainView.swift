import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case share, importer, cleanup, duplicates
    var id: String { rawValue }

    var title: String {
        switch self {
        case .share: "Sharing"
        case .importer: "Import"
        case .cleanup: "Clean Up"
        case .duplicates: "Find Duplicates"
        }
    }

    var subtitle: String {
        switch self {
        case .share: "Your libraries as a website"
        case .importer: "Copy photos between libraries"
        case .cleanup: "Remove what’s safely imported"
        case .duplicates: "Merge copies in one library"
        }
    }

    var symbol: String {
        switch self {
        case .share: "globe"
        case .importer: "square.and.arrow.down.on.square"
        case .cleanup: "checkmark.shield"
        case .duplicates: "square.on.square"
        }
    }
}

/// Which tool is showing. Tools can switch to another (e.g. Import → Clean Up).
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()
    var tool: Tool = {
        Tool(rawValue: UserDefaults.standard.string(forKey: "selectedTool") ?? "") ?? .importer
    }() {
        didSet { UserDefaults.standard.set(tool.rawValue, forKey: "selectedTool") }
    }
}

/// The app's window: tools in a sidebar. Every tool stays alive when you switch away, so an
/// import, a comparison and a scan can all run at once and keep their place.
struct MainView: View {
    @Bindable var nav: AppNavigation
    let share: ShareModel
    let importer: ImportModel
    let cleanup: CleanupModel
    let duplicates: DuplicatesModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.tool }, set: { if let t = $0 { nav.tool = t } })) {
                ForEach(Tool.allCases) { tool in
                    SidebarRow(tool: tool, status: status(tool)).tag(tool)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ZStack {
                page(.share) { ShareView(model: share) }
                page(.importer) { ImportView(model: importer) }
                page(.cleanup) { CleanupView(model: cleanup) }
                page(.duplicates) { DuplicatesView(model: duplicates) }
            }
            .navigationTitle(nav.tool.title)
        }
        .frame(minWidth: 1040, minHeight: 640)
    }

    /// A tool kept alive when hidden; hidden ones take no clicks or keyboard shortcuts.
    private func page<V: View>(_ tool: Tool, @ViewBuilder _ view: () -> V) -> some View {
        let shown = nav.tool == tool
        return view()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }

    /// What a tool is doing right now, shown under its name.
    private func status(_ tool: Tool) -> SidebarRow.Status? {
        switch tool {
        case .share:
            switch share.state {
            case .running: return .init(text: "Sharing", busy: false, tint: .green)
            case .starting: return .init(text: "Starting…", busy: true)
            case .failed: return .init(text: "Stopped with an error", busy: false, tint: .orange)
            case .stopped: return nil
            }
        case .importer:
            if importer.isImporting {
                return .init(text: importer.total > 0 ? "Importing \(importer.done) of \(importer.total)" : "Importing…",
                             busy: true)
            }
            if !importer.interrupted.isEmpty { return .init(text: "An import didn’t finish", busy: false, tint: .orange) }
            return nil
        case .cleanup:
            switch cleanup.state {
            case .comparing: return .init(text: "Comparing…", busy: true)
            case .acting: return .init(text: "Working…", busy: true)
            default: return nil
            }
        case .duplicates:
            switch duplicates.state {
            case .scanning:
                return .init(text: duplicates.total > 0 ? "Scanning \(duplicates.done) of \(duplicates.total)" : "Scanning…",
                             busy: true)
            case .working: return .init(text: "Working…", busy: true)
            case .ready where !duplicates.groups.isEmpty:
                return .init(text: "\(duplicates.groups.count) groups found", busy: false)
            default: return nil
            }
        }
    }
}

struct SidebarRow: View {
    struct Status {
        var text: String
        var busy: Bool
        var tint: Color = .secondary
    }

    let tool: Tool
    let status: Status?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                Text(status?.text ?? tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(status?.tint ?? .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status?.busy == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
