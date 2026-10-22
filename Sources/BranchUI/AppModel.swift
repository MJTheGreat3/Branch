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
public final class AppModel: ObservableObject {
    @Published private(set) var nodes: [FolderNode] = []
    @Published public private(set) var tree = FolderTree([])
    @Published private(set) var totals = Store.FileTotals()
    @Published private(set) var jobCounts = Store.JobCounts()
    @Published private(set) var quota: DriveQuota?
    @Published private(set) var quotaLevel: QuotaLevel = .ok
    @Published private(set) var notificationsEnabled = true
    @Published private(set) var globalPatterns: [String] = ExclusionRules.defaultPatterns
    @Published private(set) var isSignedIn = false
    @Published private(set) var isOnline = true
    @Published var clientID: String = ""
    @Published var errorMessage: String?
    @Published public var selection: Int64?
    /// Folder whose contents browser is open.
    @Published public var browsingID: Int64?
    @Published private(set) var isRestoring = false
    @Published private(set) var restoreProgress = ""

    let store: Store
    let library: FolderLibrary
    let engine: BackupEngine
    let auth: AuthManager

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var reloadPending = false
    private let notifier = Notifier()
    /// Last folder snapshot, for turning state changes into notifications. nil until the first load.
    private var lastFolders: [ManagedFolder]?
    private var lastQuotaCheck = Date.distantPast
    private static let notificationsKey = "notifications.enabled"
    private static let quotaInterval: TimeInterval = 30 * 60
    private static let clientIDKey = "auth.clientID"
    private static let tickInterval: TimeInterval = 60
    static let jobRowsShown = 50

    public convenience init() {
        do {
            self.init(store: try Store(db: Database(path: Store.defaultURL().path)))
        } catch {
            // Fall back to memory so the UI can still explain the problem.
            self.init(store: try! Store(db: Database(path: ":memory:")))
            errorMessage = "Could not open database: \(error.localizedDescription)"
        }
    }

    /// `live: false` loads state without starting the engine, timers or Keychain access (for snapshots).
    public init(store: Store, live: Bool = true, keychain: Keychain = Keychain()) {
        self.store = store
        library = FolderLibrary(store: store)
        let savedClientID = (try? store.setting(Self.clientIDKey)) ?? nil
        clientID = savedClientID ?? ""
        auth = AuthManager(config: savedClientID.map { AuthConfig(clientID: $0) }, keychain: keychain)
        engine = BackupEngine(store: store, drive: nil)
        notificationsEnabled = ((try? store.setting(Self.notificationsKey)) ?? nil) != "0"
        notifier.enabled = notificationsEnabled
        if live {
            notifier.requestAuthorization()
            start()
        } else {
            reload()
        }
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
            Task { @MainActor in
                await self?.engine.tick()
                await self?.refreshQuotaIfDue()
            }
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

            let folders = Array(tree.folders.values)
            if let previous = lastFolders {
                BackupEvent.changes(from: previous, to: folders).forEach(notifier.post)
            }
            lastFolders = folders
            updateQuotaLevel()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func node(_ f: ManagedFolder) -> FolderNode {
        // Excluded items live in the contents browser, not the sidebar.
        let kids = (tree.children[f.id] ?? []).filter { !$0.isExcluded }.map(node)
        return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
    }

    public var overallStatus: BackupStatus {
        if jobCounts.failed > 0 || tree.folders.values.contains(where: { $0.status == .needsAttention }) { return .needsAttention }
        if jobCounts.uploading > 0 { return .uploading }
        if jobCounts.queued > 0 || totals.uploadedCount < totals.count { return .queued }
        if tree.folders.isEmpty { return .idle }
        return .backedUp
    }

    func jobCounts(for folderID: Int64) -> Store.JobCounts {
        (try? store.jobCounts(folderID: folderID)) ?? Store.JobCounts()
    }

    func jobs(for folderID: Int64) -> [UploadJob] {
        (try? store.jobs(folderID: folderID, limit: Self.jobRowsShown)) ?? []
    }

    func fileTotals(rootID: Int64) -> Store.FileTotals? {
        try? store.fileTotals(rootID: rootID)
    }

    // MARK: Folder actions

    /// Adds folders. A new top-level folder opens its contents browser so the user can untick items.
    func addFolders(_ urls: [URL], browse: Bool = true) {
        for url in urls {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            perform {
                var f = try library.add(path: url.path, bookmark: bookmark)
                selection = f.id
                if browse && f.isRoot && urls.count == 1 {
                    // Hold the first backup while the user picks items; Done starts it.
                    // The fallback keeps a forgotten sheet from blocking backups forever.
                    f.nextRun = Date().addingTimeInterval(Self.firstRunGrace)
                    try store.update(f)
                    browsingID = f.id
                }
            }
        }
        backUpDueNow()
    }

    private static let firstRunGrace: TimeInterval = 10 * 60

    /// Called when the contents browser closes.
    func finishBrowsing(_ id: Int64) {
        browsingID = nil
        if let f = tree.folders[id], f.isRoot, f.lastSuccess == nil {
            backUpNow(id)
        }
    }

    func setIncluded(_ path: String, _ included: Bool) {
        perform { try library.setIncluded(path: path, included) }
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

    /// Restores a stand-in (e.g. double-clicked in Finder) and optionally opens the file.
    public func restore(standIn url: URL, open: Bool) {
        Task {
            do {
                let restored = try await engine.restore(standInPath: url.path)
                if open { NSWorkspace.shared.open(URL(fileURLWithPath: restored)) }
            } catch {
                errorMessage = BackupEngine.message(for: error)
            }
            reload()
        }
    }

    func restoreAll(_ id: Int64) {
        guard let folder = tree.folders[id], !isRestoring else { return }
        isRestoring = true
        restoreProgress = "Downloading…"
        Task {
            let result = await engine.restoreAll(under: folder.path)
            isRestoring = false
            restoreProgress = ""
            if !result.failures.isEmpty {
                errorMessage = "Restored \(result.restored) files; \(result.failures.count) couldn't be restored:\n"
                    + result.failures.prefix(5).joined(separator: "\n")
            }
            reload()
        }
    }

    func setPaused(_ id: Int64, _ paused: Bool) {
        perform { try library.setPaused(id: id, paused) }
        if !paused { backUpDueNow() }
    }

    func backUpNow(_ id: Int64) {
        perform { try library.scheduleNow(id: id) }
        backUpDueNow()
    }

    public func backUpAllNow() {
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
            await refreshQuota()
            await engine.processQueue()
        } else {
            quota = nil
            updateQuotaLevel()
        }
    }

    private func refreshQuotaIfDue() async {
        guard isSignedIn, Date().timeIntervalSince(lastQuotaCheck) > Self.quotaInterval else { return }
        await refreshQuota()
    }

    /// Quota may be unavailable with app-folder-only permission; then no warnings are shown.
    private func refreshQuota() async {
        lastQuotaCheck = Date()
        quota = try? await GraphDrive(tokens: auth).quota()
        updateQuotaLevel()
    }

    private func updateQuotaLevel() {
        let level = quota.map { QuotaLevel.assess($0, pendingBytes: totals.bytes - totals.uploadedBytes) } ?? .ok
        if let event = BackupEvent.quotaChange(from: quotaLevel, to: level) {
            notifier.post(event)
        }
        quotaLevel = level
    }

    func setNotificationsEnabled(_ on: Bool) {
        notificationsEnabled = on
        notifier.enabled = on
        try? store.setSetting(Self.notificationsKey, on ? nil : "0")
        if on { notifier.requestAuthorization() }
    }

    func signOut() {
        Task {
            await auth.signOut()
            await refreshAuthState()
        }
    }
}
