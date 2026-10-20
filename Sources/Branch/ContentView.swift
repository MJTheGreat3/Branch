import BranchCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingImporter = false
    @State private var showingAccount = false

    var body: some View {
        NavigationSplitView {
            FolderListView(showingImporter: $showingImporter)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = model.selection, let folder = model.tree.folders[id] {
                FolderDetailView(folder: folder)
                    .id(id)
            } else {
                DashboardView(showingImporter: $showingImporter, showingAccount: $showingAccount)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    model.backUpAllNow()
                } label: {
                    Label("Back Up All Now", systemImage: "arrow.clockwise.icloud")
                }
                .disabled(model.tree.folders.isEmpty)
                Button {
                    showingAccount = true
                } label: {
                    Label("Account", systemImage: model.isSignedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.addFolders(urls) }
        }
        .sheet(isPresented: $showingAccount) {
            AccountView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// Compact status and actions in the menu bar.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Branch — \(model.overallStatus.label)")
        Text("\(model.totals.uploadedCount) of \(model.totals.count) files backed up")
        if model.jobCounts.queued + model.jobCounts.uploading > 0 {
            Text("\(model.jobCounts.queued + model.jobCounts.uploading) uploads pending")
        }
        if model.jobCounts.failed > 0 {
            Button("Retry \(model.jobCounts.failed) Failed") { model.retryFailed() }
        }
        Divider()
        Button("Back Up All Now") { model.backUpAllNow() }
            .disabled(model.tree.folders.isEmpty)
        Button("Open Branch") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Branch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
