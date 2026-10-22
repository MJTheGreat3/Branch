import AppKit
import BranchCore
import SwiftUI

/// A file or folder on disk shown in the contents browser.
struct DiskEntry: Identifiable, Hashable {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    var id: String { path }

    /// Lists a directory, folders first, skipping hidden items unless asked.
    static func children(of path: String, showHidden: Bool) -> [DiskEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        return items.map { item in
            let v = try? item.resourceValues(forKeys: Set(keys))
            let link = v?.isSymbolicLink == true
            return DiskEntry(
                path: item.standardizedFileURL.path,
                name: item.lastPathComponent,
                // Packages (apps, bundles) back up as a unit, so don't offer to expand them.
                isDirectory: !link && v?.isDirectory == true && v?.isPackage != true,
                isSymlink: link
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Checkbox tree of a managed folder's real contents: tick what to back up.
public struct ContentsBrowser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let folder: ManagedFolder

    public init(folder: ManagedFolder, expanded: Set<String> = []) {
        self.folder = folder
        _expanded = State(initialValue: expanded)
    }

    @State private var expanded: Set<String>
    @State private var cache: [String: [DiskEntry]] = [:]
    @State private var showHidden = false
    @State private var search = ""

    private struct Row: Identifiable {
        let entry: DiskEntry
        let depth: Int
        /// An ancestor is unticked or skipped, so this item can't be backed up on its own.
        let blockedByParent: Bool
        var id: String { entry.id }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(rows) { row in
                    EntryRow(
                        entry: row.entry,
                        depth: row.depth,
                        state: row.blockedByParent ? .excluded : state(of: row.entry),
                        blockedByParent: row.blockedByParent,
                        isExpanded: expanded.contains(row.entry.path),
                        managed: model.tree.folders.values.first { $0.path == row.entry.path && !$0.isExcluded },
                        onToggleExpand: { toggleExpand(row.entry) },
                        onToggleIncluded: { toggleIncluded(row.entry) },
                        onCustomSettings: { customSettings(row.entry) }
                    )
                    .listRowSeparator(.hidden)
                }
                if rows.isEmpty {
                    Text(search.isEmpty ? "This folder is empty." : "Nothing here matches “\(search)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 480, idealHeight: 560)
        .onAppear {
            load(folder.path)
            expanded.forEach(load)
        }
        .onChange(of: showHidden) { _, _ in
            cache = [:]
            load(folder.path)
            expanded.forEach(load)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose what to back up in “\(folder.name)”")
                .font(.headline)
            Text("Untick folders or files to leave them out. New items inside a ticked folder are backed up automatically. Unticking never deletes anything, here or in OneDrive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Filter names", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Toggle("Show hidden items", isOn: $showHidden)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Expand All") { expandAll() }
                Button("Collapse All") { expanded = [] }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            let n = model.tree.excludedCount(under: folder.id)
            Text(n == 0 ? "Everything is included." : "\(n) item\(n == 1 ? "" : "s") left out.")
                .foregroundStyle(.secondary)
            Text("Greyed items are skipped by patterns in Account.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Rows

    private var rows: [Row] {
        var out: [Row] = []
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        func walk(_ path: String, depth: Int, blocked: Bool) {
            for entry in cache[path] ?? [] {
                let s = blocked ? FolderTree.Inclusion.excluded : state(of: entry)
                let childBlocked = blocked || s == .excluded || s == .skippedByPattern
                if needle.isEmpty || entry.name.lowercased().contains(needle) {
                    out.append(Row(entry: entry, depth: depth, blockedByParent: blocked))
                }
                if entry.isDirectory, expanded.contains(entry.path) {
                    walk(entry.path, depth: depth + 1, blocked: childBlocked)
                }
            }
        }
        walk(folder.path, depth: 0, blocked: false)
        return out
    }

    private func state(of entry: DiskEntry) -> FolderTree.Inclusion {
        model.tree.inclusion(of: entry.path, globalPatterns: model.globalPatterns)
    }

    private func load(_ path: String) {
        if cache[path] == nil {
            cache[path] = DiskEntry.children(of: path, showHidden: showHidden)
        }
    }

    private func toggleExpand(_ entry: DiskEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            load(entry.path)
            expanded.insert(entry.path)
        }
    }

    /// Expands two levels; deeper trees can be opened by hand.
    private func expandAll() {
        for e in cache[folder.path] ?? [] where e.isDirectory {
            load(e.path)
            expanded.insert(e.path)
        }
    }

    private func toggleIncluded(_ entry: DiskEntry) {
        switch state(of: entry) {
        case .excluded: model.setIncluded(entry.path, true)
        case .included, .partial: model.setIncluded(entry.path, false)
        case .skippedByPattern, .outside: break
        }
    }

    private func customSettings(_ entry: DiskEntry) {
        if let existing = model.tree.folders.values.first(where: { $0.path == entry.path }) {
            model.selection = existing.id
        } else {
            model.addFolders([URL(fileURLWithPath: entry.path)], browse: false)
        }
        dismiss()
    }
}

private struct EntryRow: View {
    let entry: DiskEntry
    let depth: Int
    let state: FolderTree.Inclusion
    let blockedByParent: Bool
    let isExpanded: Bool
    let managed: ManagedFolder?
    let onToggleExpand: () -> Void
    let onToggleIncluded: () -> Void
    let onCustomSettings: () -> Void

    private var dimmed: Bool {
        blockedByParent || state == .skippedByPattern || state == .excluded || entry.isSymlink
    }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(depth) * 18, height: 1)
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .opacity(entry.isDirectory ? 1 : 0)
            .disabled(!entry.isDirectory)

            Button(action: onToggleIncluded) {
                Image(systemName: checkboxSymbol)
                    .font(.body)
                    .foregroundStyle(checkboxTint)
            }
            .buttonStyle(.plain)
            .disabled(blockedByParent || state == .skippedByPattern || entry.isSymlink)
            .help(checkboxHelp)

            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .strikethrough(state == .excluded && !blockedByParent)

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let managed, managed.intervalOverride != nil || managed.availabilityOverride != nil
                || managed.isPaused || !managed.excludePatterns.isEmpty {
                Button("Custom settings", action: onCustomSettings)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Open this folder's own schedule and settings")
            }
            if entry.isDirectory && !dimmed {
                Menu {
                    Button("Set Different Settings…", action: onCustomSettings)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if entry.isDirectory { onToggleExpand() } }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
            if entry.isDirectory && !dimmed {
                Button("Set Different Settings…", action: onCustomSettings)
            }
        }
    }

    private var checkboxSymbol: String {
        if blockedByParent || entry.isSymlink { return "square.dashed" }
        switch state {
        case .included: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .excluded, .outside: return "square"
        case .skippedByPattern: return "square.slash"
        }
    }

    private var checkboxTint: Color {
        switch state {
        case .included, .partial: return blockedByParent ? .secondary : .accentColor
        default: return .secondary
        }
    }

    private var checkboxHelp: String {
        if entry.isSymlink { return "Links and aliases aren't backed up." }
        if blockedByParent { return "Tick the enclosing folder to choose items inside it." }
        switch state {
        case .included: return "Backed up. Click to leave out."
        case .partial: return "Backed up, except some items inside. Click to leave out entirely."
        case .excluded: return "Left out. Click to back up."
        case .skippedByPattern: return "Skipped by a pattern. Edit skip patterns in Account to include it."
        case .outside: return ""
        }
    }

    private var caption: String? {
        if entry.isSymlink { return "link — not backed up" }
        if blockedByParent { return nil }
        switch state {
        case .skippedByPattern: return "skipped by pattern"
        case .partial: return "some items left out"
        default: return nil
        }
    }
}
