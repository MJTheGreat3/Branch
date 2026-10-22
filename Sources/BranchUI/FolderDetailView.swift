import BranchCore
import SwiftUI

/// Settings and status for one managed folder.
struct FolderDetailView: View {
    @EnvironmentObject var model: AppModel
    let folder: ManagedFolder
    @State private var confirmingRemove = false
    @State private var confirmingCloudOnly: AvailabilityMode?? = nil
    @State private var confirmingRestoreAll = false
    @State private var patternsText = ""

    private var policy: EffectivePolicy { model.tree.policy(for: folder.id) }
    private var root: ManagedFolder? { model.tree.root(of: folder.id) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(folder.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let root, let name = root.remoteName {
                    let rel = FolderTree.relative(folder.path, to: root.path) ?? ""
                    LabeledContent("OneDrive") {
                        Text("Apps/Branch/\(name)\(rel.isEmpty ? "" : "/" + rel)")
                            .textSelection(.enabled)
                    }
                }
                LabeledContent("Status") { StatusBadge(status: policy.isPaused ? .paused : folder.status) }
                if let error = folder.lastError {
                    LabeledContent("Problem") {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                LabeledContent("Last successful backup") { Text(Format.relative(folder.lastSuccess)) }
                LabeledContent("Next scheduled attempt") {
                    Text(policy.isPaused || policy.isExcluded ? "—" : Format.relative(folder.nextRun, placeholder: "Soon"))
                }
                if folder.isRoot, let t = model.fileTotals(rootID: folder.id) {
                    LabeledContent("Files backed up") {
                        Text("\(t.uploadedCount) of \(t.count) · \(Format.bytes(t.uploadedBytes)) of \(Format.bytes(t.bytes))")
                    }
                }
            }

            if !policy.isExcluded {
                Section {
                    let leftOut = model.tree.folders.values
                        .filter { $0.isExcluded && $0.id != folder.id && FolderTree.relative($0.path, to: folder.path) != nil }
                        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    if leftOut.isEmpty {
                        Label("Everything inside is backed up", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(leftOut) { item in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(FolderTree.relative(item.path, to: folder.path) ?? item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("left out").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Include") { model.setIncluded(item.path, true) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    let custom = (model.tree.children[folder.id] ?? []).filter { !$0.isExcluded }
                    ForEach(custom) { child in
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(.secondary)
                            Text(child.name)
                            Text(model.tree.policy(for: child.id).interval.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open") { model.selection = child.id }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button {
                            model.browsingID = folder.id
                        } label: {
                            Label("Choose Items to Back Up…", systemImage: "checklist")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } header: {
                    Text("Contents")
                } footer: {
                    Text("Tick or untick subfolders and files, or give a subfolder its own schedule.")
                }
            }

            if !policy.isExcluded {
                Section {
                    Picker("Backup schedule", selection: intervalBinding) {
                        Text(inheritLabel(policy.interval.label)).tag(BackupInterval?.none)
                        Divider()
                        ForEach(BackupInterval.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Toggle("Pause backups", isOn: Binding(
                        get: { folder.isPaused },
                        set: { model.setPaused(folder.id, $0) }
                    ))
                } header: {
                    Text("Backup")
                } footer: {
                    Text("How often Branch copies new and changed files to OneDrive. This is a target: sleep, network and login state can delay a run. Local deletions are never removed from OneDrive.")
                }

                Section {
                    Picker("Local availability", selection: availabilityBinding) {
                        Text(inheritLabel(policy.availability.label)).tag(AvailabilityMode?.none)
                        Divider()
                        ForEach(AvailabilityMode.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Text(policy.availability.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let root, let t = model.fileTotals(rootID: root.id), t.offloadedCount > 0 {
                        LabeledContent("In OneDrive only") {
                            Text("\(Format.count(t.offloadedCount, "file")) · \(Format.bytes(t.offloadedBytes)) freed")
                        }
                        HStack {
                            Button("Restore All Files…") { confirmingRestoreAll = true }
                                .disabled(model.isRestoring)
                            if model.isRestoring {
                                ProgressView().controlSize(.small)
                                Text(model.restoreProgress).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    Text("Separate from the schedule: it controls whether file contents stay on this Mac, not how often they're backed up.")
                }
            }

            if !policy.isExcluded {
                Section {
                    TextField("Extra patterns", text: $patternsText, prompt: Text(verbatim: "e.g. *.raw, cache, exports/*"))
                        .font(.body.monospaced())
                        .onSubmit { model.setExcludePatterns(folder.id, patternsText) }
                    if ExclusionRules.parse(patternsText) != folder.excludePatterns {
                        Button("Save Patterns") { model.setExcludePatterns(folder.id, patternsText) }
                    }
                    let inherited = model.globalPatterns + (folder.parentID.map { model.tree.excludePatterns(for: $0) } ?? [])
                    if !inherited.isEmpty {
                        Text("Also skipped: \(inherited.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Skipped files")
                } footer: {
                    Text("Comma-separated patterns for this folder and its subfolders, added to the global list in Account. Files already in OneDrive are kept.")
                }
            }

            let counts = model.jobCounts(for: folder.id)
            let total = counts.queued + counts.uploading + counts.failed
            if total > 0 {
                Section {
                    LabeledContent("Waiting") {
                        Text("\(counts.queued) queued · \(counts.uploading) uploading · \(counts.failed) failed")
                            .monospacedDigit()
                    }
                    // Only a slice is drawn; a big first backup can queue hundreds of thousands of files.
                    ForEach(model.jobs(for: folder.id)) { JobRow(job: $0) }
                    if total > AppModel.jobRowsShown {
                        Text("…and \(total - AppModel.jobRowsShown) more")
                            .foregroundStyle(.secondary)
                    }
                    if counts.failed > 0 {
                        Button("Retry Failed Uploads") { model.retryFailed(folder.id) }
                    }
                } header: {
                    Text("Pending uploads")
                }
            }

            Section {
                HStack {
                    Button("Back Up Now") { model.backUpNow(folder.id) }
                        .disabled(policy.isPaused || policy.isExcluded)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                    }
                    Spacer()
                    Button("Stop Managing…", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(folder.name)
        .onAppear { patternsText = folder.excludePatterns.joined(separator: ", ") }
        .confirmationDialog(
            "Free up space in “\(folder.name)”?",
            isPresented: Binding(get: { confirmingCloudOnly != nil }, set: { if !$0 { confirmingCloudOnly = nil } })
        ) {
            Button("Make Cloud-only") {
                if case .some(let mode) = confirmingCloudOnly { model.setAvailability(folder.id, mode) }
                confirmingCloudOnly = nil
            }
        } message: {
            Text("After each file is verified in OneDrive and has been unchanged for 5 minutes, Branch moves the local copy to the Trash and leaves a small “.branch” stand-in. Double-click a stand-in to download it again. Space is freed when you empty the Trash.")
        }
        .confirmationDialog(
            "Restore all files in “\(folder.name)”?",
            isPresented: $confirmingRestoreAll
        ) {
            Button("Restore and Keep on This Mac") {
                if folder.availabilityOverride == .cloudOnly { model.setAvailability(folder.id, nil) }
                model.restoreAll(folder.id)
            }
        } message: {
            Text("Downloads every file that's currently in OneDrive only and switches this folder back to keeping files on this Mac. Make sure there's enough free disk space.")
        }
        .confirmationDialog(
            "Stop managing “\(folder.name)”?",
            isPresented: $confirmingRemove
        ) {
            Button("Stop Managing", role: .destructive) { model.remove(folder.id) }
        } message: {
            Text("Branch will stop backing up this folder\(folder.isRoot ? " and its subfolder settings" : ""). Files on your Mac and copies already in OneDrive are not deleted.")
        }
    }

    private func inheritLabel(_ value: String) -> String {
        folder.isRoot ? "Default (\(value))" : "Same as parent (\(value))"
    }

    private var intervalBinding: Binding<BackupInterval?> {
        Binding(get: { folder.intervalOverride }, set: { model.setInterval(folder.id, $0) })
    }

    /// Switching to cloud-only removes local copies, so it's confirmed first.
    private var availabilityBinding: Binding<AvailabilityMode?> {
        Binding(get: { folder.availabilityOverride }, set: { newValue in
            let inherited = folder.parentID.map { model.tree.policy(for: $0).availability } ?? FolderTree.defaultAvailability
            let effective = newValue ?? inherited
            if effective == .cloudOnly && policy.availability != .cloudOnly {
                confirmingCloudOnly = .some(newValue)
            } else {
                model.setAvailability(folder.id, newValue)
            }
        })
    }
}

struct JobRow: View {
    let job: UploadJob

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading) {
                Text(job.relativePath).lineLimit(1).truncationMode(.middle)
                if let e = job.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer()
            if job.state == .uploading, job.size > 0, job.bytesUploaded > 0 {
                ProgressView(value: Double(job.bytesUploaded), total: Double(job.size))
                    .frame(width: 80)
            }
            Text(Format.bytes(job.size)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var icon: String {
        switch job.state {
        case .queued: return job.attempts > 0 ? "arrow.clockwise" : "clock"
        case .uploading: return "arrow.up.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle"
        }
    }

    private var tint: Color {
        job.state == .failed ? .orange : .blue
    }
}
