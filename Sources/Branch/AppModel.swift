import AppKit
import BranchCore
import Network
import SwiftUI

/// Tree node for OutlineGroup.
struct FolderNode: Identifiable, Hashable {
    var folder: ManagedFolder
    var children: [FolderNode]?
    var id: Int64 { folder.id }
}

/// Main-actor façade over the core: loads state for the UI and drives the engine.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var nodes: [FolderNode] = []
    @Published private(set) var tree = FolderTree([])
    @Published private(set) var totals = Store.FileTotals()
    @Published private(set) var jobCounts = Store.JobCounts()
    @Published private(set) var quota: DriveQuota?
    @Published private(set) var globalPatterns: [String] = ExclusionRules.defaultPatterns
    @Published private(set) var isSignedIn = false
    @Published private(set) var isOnline = true
    @Published var clientID: String = ""
    @Published var errorMessage: String?
    @Published var selection: Int64?

    let store: Store
    let library: FolderLibrary
    let engine: BackupEngine
    let auth: AuthManager

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var reloadPending = false
    private static let clientIDKey = "auth.clientID"
    private static let tickInterval: TimeInterval = 60

    init() {
        do {
            store = try Store(db: Database(path: Store.defaultURL().path))
        } catch {
            // Fall back to memory so the UI can still explain the problem.
            store = try! Store(db: Database(path: ":memory:"))
            errorMessage = "Could not open database: \(error.localizedDescription)"
        }
        library = FolderLibrary(store: store)
        let savedClientID = (try? store.setting(Self.clientIDKey)) ?? nil
        clientID = savedClientID ?? ""
        auth = AuthManager(config: savedClientID.map { AuthConfig(clientID: $0) })
        engine = BackupEngine(store: store, drive: nil)
        start()
    }

    private func start() {
        reload()
        Task {
            try? await engine.recover()
            await engine.setOnChange { [weak self] in
                Task { @MainActor in self?.scheduleReload() }
            }
            await refreshAuthState()
            await engine.tick()
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.engine.tick() }
        }

        // Catch up after sleep and when the network returns.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.engine.tick() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = online && !self.isOnline
                self.isOnline = online
                if cameBack { await self.engine.tick() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "branch.network"))
    }

    // MARK: State

    /// Coalesces bursts of engine notifications into one reload.
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
    }

    func reload() {
        do {
            tree = try library.tree()
            nodes = tree.roots.map(node)
            totals = try store.fileTotals()
            jobCounts = try store.jobCounts()
            globalPatterns = try store.exclusionPatterns()
            if let s = selection, tree.folders[s] == nil { selection = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func node(_ f: ManagedFolder) -> FolderNode {
        let kids = (tree.children[f.id] ?? []).map(node)
        return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
    }

    var overallStatus: BackupStatus {
        if jobCounts.failed > 0 || tree.folders.values.contains(where: { $0.status == .needsAttention }) { return .needsAttention }
        if jobCounts.uploading > 0 { return .uploading }
        if jobCounts.queued > 0 { return .queued }
        if tree.folders.isEmpty { return .idle }
        return .backedUp
    }

    func jobs(for folderID: Int64) -> [UploadJob] {
        (try? store.jobs(folderID: folderID)) ?? []
    }

    func fileTotals(rootID: Int64) -> Store.FileTotals? {
        try? store.fileTotals(rootID: rootID)
    }

    // MARK: Folder actions

    func addFolders(_ urls: [URL]) {
        for url in urls {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            perform {
                let f = try library.add(path: url.path, bookmark: bookmark)
                selection = f.id
            }
        }
        backUpDueNow()
    }

    func exclude(_ url: URL) {
        perform { try library.exclude(path: url.path) }
    }

    func remove(_ id: Int64) {
        perform { try library.remove(id: id) }
    }

    func setInterval(_ id: Int64, _ interval: BackupInterval?) {
        perform { try library.setInterval(id: id, interval) }
    }

    func setAvailability(_ id: Int64, _ mode: AvailabilityMode?) {
        perform { try library.setAvailability(id: id, mode) }
    }

    func setExcludePatterns(_ id: Int64, _ text: String) {
        perform { try library.setExcludePatterns(id: id, ExclusionRules.parse(text)) }
    }

    /// nil restores the built-in defaults.
    func setGlobalPatterns(_ text: String?) {
        perform { try store.setExclusionPatterns(text.map(ExclusionRules.parse)) }
    }

    func setPaused(_ id: Int64, _ paused: Bool) {
        perform { try library.setPaused(id: id, paused) }
        if !paused { backUpDueNow() }
    }

    func setExcluded(_ id: Int64, _ excluded: Bool) {
        guard let f = tree.folders[id] else { return }
        perform { try library.exclude(path: f.path, excluded) }
    }

    func backUpNow(_ id: Int64) {
        perform { try library.scheduleNow(id: id) }
        backUpDueNow()
    }

    func backUpAllNow() {
        perform {
            for f in tree.folders.values { try library.scheduleNow(id: f.id) }
        }
        backUpDueNow()
    }

    func retryFailed(_ id: Int64? = nil) {
        perform { try store.retryFailedJobs(folderID: id) }
        Task { await engine.processQueue() }
    }

    private func backUpDueNow() {
        Task { await engine.tick() }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = String(describing: error)
        }
        reload()
    }

    // MARK: Account

    func saveClientID() {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = trimmed
        try? store.setSetting(Self.clientIDKey, trimmed.isEmpty ? nil : trimmed)
        Task {
            await auth.setConfig(trimmed.isEmpty ? nil : AuthConfig(clientID: trimmed))
            await refreshAuthState()
        }
    }

    func refreshAuthState() async {
        isSignedIn = await auth.isSignedIn
        await engine.setDrive(isSignedIn ? GraphDrive(tokens: auth) : nil)
        if isSignedIn {
            quota = try? await GraphDrive(tokens: auth).quota()
            await engine.processQueue()
        } else {
            quota = nil
        }
    }

    func signOut() {
        Task {
            await auth.signOut()
            await refreshAuthState()
        }
    }
}
