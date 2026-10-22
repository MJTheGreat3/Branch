import BranchCore
import SwiftUI

/// Overview of everything Branch manages.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showingImporter: Bool
    @Binding var showingAccount: Bool

    var body: some View {
        Form {
            if !model.isSignedIn {
                Section {
                    Label("Sign in to OneDrive to start uploading. Changes are queued until then.", systemImage: "person.crop.circle.badge.exclamationmark")
                    Button("Set Up OneDrive…") { showingAccount = true }
                }
            }
            if let message = model.quotaLevel.message {
                Section {
                    Label(message, systemImage: model.quotaLevel >= .insufficient ? "exclamationmark.icloud.fill" : "icloud")
                        .foregroundStyle(model.quotaLevel >= .insufficient ? .red : .orange)
                    Text("Free up space in OneDrive, or untick large items with Choose Items to Back Up.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.isOnline {
                Section {
                    Label("Offline. Backups are queued and will catch up when the connection returns.", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
            }

            Section("Status") {
                LabeledContent("Overall") { StatusBadge(status: model.overallStatus) }
                LabeledContent("Managed folders") { Text("\(model.tree.roots.count)") }
                LabeledContent("Files backed up") {
                    Text("\(model.totals.uploadedCount) of \(model.totals.count)").monospacedDigit()
                }
                LabeledContent("Waiting to upload") {
                    Text("\(Format.count(model.totals.count - model.totals.uploadedCount, "file")) · \(Format.bytes(model.totals.bytes - model.totals.uploadedBytes))")
                        .monospacedDigit()
                }
                LabeledContent("Queued / uploading") {
                    Text("\(model.jobCounts.queued) / \(model.jobCounts.uploading)").monospacedDigit()
                }
                LabeledContent("Failed") {
                    HStack {
                        Text("\(model.jobCounts.failed)").monospacedDigit()
                        if model.jobCounts.failed > 0 {
                            Button("Retry All") { model.retryFailed() }
                        }
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Managed content on this Mac") { Text(Format.bytes(model.totals.bytes)) }
                LabeledContent("Backed up to OneDrive") { Text(Format.bytes(model.totals.uploadedBytes)) }
                if let q = model.quota {
                    LabeledContent("OneDrive used") {
                        Text("\(Format.bytes(q.used)) of \(Format.bytes(q.total))")
                    }
                    ProgressView(value: Double(q.used), total: Double(max(q.total, 1)))
                }
            }

            Section("Folders") {
                if model.tree.roots.isEmpty {
                    Button("Add a Folder…") { showingImporter = true }
                }
                ForEach(model.tree.folders.values.sorted { $0.path < $1.path }) { f in
                    let p = model.tree.policy(for: f.id)
                    if !p.isExcluded {
                        Button {
                            model.selection = f.id
                        } label: {
                            HStack {
                                Text(f.name)
                                Spacer()
                                Text("\(f.lastSuccess == nil ? "Not backed up yet" : "Last " + Format.relative(f.lastSuccess)) · Next \(p.isPaused ? "paused" : Format.relative(f.nextRun, placeholder: "soon"))")
                                    .foregroundStyle(.secondary)
                                Image(systemName: (p.isPaused ? BackupStatus.paused : f.status).symbol)
                                    .foregroundStyle((p.isPaused ? BackupStatus.paused : f.status).tint)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
    }
}
