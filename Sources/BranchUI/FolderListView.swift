import BranchCore
import SwiftUI

/// Sidebar: managed folders as a tree with status, schedule and last backup.
struct FolderListView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showingImporter: Bool

    var body: some View {
        List(selection: $model.selection) {
            Section {
                NavigationLink(value: Int64?.none) {
                    Label("Overview", systemImage: "gauge.with.dots.needle.33percent")
                }
                .tag(Int64?.none)
            }
            Section("Folders") {
                if model.nodes.isEmpty {
                    Text("No folders yet")
                        .foregroundStyle(.secondary)
                }
                OutlineGroup(model.nodes, children: \.children) { node in
                    FolderRow(folder: node.folder, policy: model.tree.policy(for: node.id))
                        .tag(Optional(node.id))
                        .contextMenu { menu(for: node.folder) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func menu(for f: ManagedFolder) -> some View {
        Button("Back Up Now") { model.backUpNow(f.id) }
        Button(f.isPaused ? "Resume" : "Pause") { model.setPaused(f.id, !f.isPaused) }
        Button("Choose Items to Back Up…") { model.browsingID = f.id }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
        }
        Divider()
        Button("Stop Managing…") { model.selection = f.id }
    }
}

struct FolderRow: View {
    let folder: ManagedFolder
    let policy: EffectivePolicy

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: policy.isExcluded ? "folder.badge.minus" : "folder")
                .foregroundStyle(policy.isExcluded ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                    .strikethrough(policy.isExcluded)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !policy.isExcluded {
                Image(systemName: rowStatus.symbol)
                    .foregroundStyle(rowStatus.tint)
                    .help(folder.lastError ?? rowStatus.label)
            }
        }
    }

    private var rowStatus: BackupStatus {
        policy.isPaused ? .paused : folder.status
    }

    private var subtitle: String {
        if policy.isExcluded { return "Excluded" }
        let mode = policy.availability == .cloudOnly ? " · Cloud-only" : ""
        return "\(policy.interval.label)\(mode) · \(Format.relative(folder.lastSuccess))"
    }
}
