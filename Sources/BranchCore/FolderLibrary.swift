import Foundation

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case alreadyManaged(String)
    case notADirectory(String)
    case outsideManagedRoots(String)

    public var description: String {
        switch self {
        case .alreadyManaged(let p): return "\(p) is already managed."
        case .notADirectory(let p): return "\(p) is not a folder."
        case .outsideManagedRoots(let p): return "\(p) is not inside a managed folder."
        }
    }
}

/// Add, remove and configure managed folders. Never modifies files on disk or in the cloud.
public struct FolderLibrary: Sendable {
    public let store: Store

    public init(store: Store) {
        self.store = store
    }

    public func tree() throws -> FolderTree {
        FolderTree(try store.allFolders())
    }

    /// Adds a folder chosen by the user. Inside an existing root it becomes an override node;
    /// otherwise it becomes a new root. Existing roots inside it are re-parented under it.
    @discardableResult
    public func add(path rawPath: String, bookmark: Data? = nil) throws -> ManagedFolder {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw LibraryError.notADirectory(path)
        }
        let tree = try tree()
        if tree.folders.values.contains(where: { $0.path == path }) {
            throw LibraryError.alreadyManaged(path)
        }
        return try store.db.transaction {
            if let parent = tree.containing(path) {
                let node = try store.insert(ManagedFolder(parentID: parent.id, path: path, bookmark: bookmark))
                try adoptDescendants(of: node, in: tree)
                return node
            }
            let root = try store.insert(ManagedFolder(
                path: path, bookmark: bookmark, remoteName: uniqueRemoteName(for: path, among: tree.roots)
            ))
            // Former roots nested in the new one: keep their settings as overrides.
            for var nested in tree.roots where FolderTree.relative(nested.path, to: path) != nil {
                // Its files are now tracked under the new root's cloud location.
                try store.db.run("DELETE FROM jobs WHERE root_id = ?", [nested.id])
                try store.db.run("DELETE FROM files WHERE root_id = ?", [nested.id])
                nested.parentID = root.id
                nested.remoteName = nil
                nested.nextRun = nil
                try store.update(nested)
            }
            return root
        }
    }

    /// Where a bookmark points now.
    public struct ResolvedBookmark: Sendable {
        public var path: String
        /// Fresh bookmark data when the old one was stale.
        public var refreshed: Data?

        public init(path: String, refreshed: Data? = nil) {
            self.path = path
            self.refreshed = refreshed
        }
    }

    public struct Relocation: Equatable, Sendable {
        public var folderID: Int64
        public var from: String
        public var to: String
    }

    /// Resolves a bookmark with the system, ignoring folders that went to the Trash.
    public static func resolveBookmark(_ data: Data) -> ResolvedBookmark? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        let path = url.standardizedFileURL.path
        if path.contains("/.Trash/") || path.hasSuffix("/.Trash") { return nil }
        let refreshed = stale ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return ResolvedBookmark(path: path, refreshed: refreshed)
    }

    /// Follows managed roots that were moved or renamed in Finder, rewriting their path and their
    /// descendants' paths. File records are relative to the root and the OneDrive destination name
    /// stays the same, so nothing is uploaded again.
    @discardableResult
    public func relocateMovedFolders(
        resolve: (Data) -> ResolvedBookmark? = FolderLibrary.resolveBookmark
    ) throws -> [Relocation] {
        let tree = try tree()
        var moves: [Relocation] = []
        for root in tree.roots {
            // Only folders missing from their recorded path need resolving.
            guard let bookmark = root.bookmark,
                  !FileManager.default.fileExists(atPath: root.path),
                  let resolved = resolve(bookmark) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if resolved.path == root.path {
                if let fresh = resolved.refreshed {
                    var r = root
                    r.bookmark = fresh
                    try store.update(r)
                }
                continue
            }
            // Don't collide with something already managed at the new location.
            guard tree.containing(resolved.path) == nil else { continue }

            try store.db.transaction {
                var r = root
                r.path = resolved.path
                r.bookmark = resolved.refreshed ?? root.bookmark
                r.status = r.lastSuccess == nil ? .idle : .backedUp
                r.lastError = nil
                r.nextRun = .distantPast
                try store.update(r)
                for d in tree.folders.values where d.id != root.id {
                    guard let rel = FolderTree.relative(d.path, to: root.path) else { continue }
                    var moved = d
                    moved.path = (resolved.path as NSString).appendingPathComponent(rel)
                    if moved.status == .needsAttention {
                        moved.status = .idle
                        moved.lastError = nil
                    }
                    try store.update(moved)
                }
            }
            moves.append(Relocation(folderID: root.id, from: root.path, to: resolved.path))
        }
        return moves
    }

    /// Marks a descendant path to be skipped by backups. Creates the node if needed.
    @discardableResult
    public func exclude(path rawPath: String, _ excluded: Bool = true) throws -> ManagedFolder {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let tree = try tree()
        if var existing = tree.folders.values.first(where: { $0.path == path }) {
            existing.isExcluded = excluded
            try store.update(existing)
            return existing
        }
        guard let parent = tree.containing(path) else { throw LibraryError.outsideManagedRoots(path) }
        return try store.db.transaction {
            let node = try store.insert(ManagedFolder(parentID: parent.id, path: path, isExcluded: excluded))
            try adoptDescendants(of: node, in: tree)
            return node
        }
    }

    /// Includes or excludes a file or folder inside a managed root (the checkbox in the contents browser).
    /// Including removes the exclusion node when it carries nothing else, keeping the tree tidy.
    public func setIncluded(path rawPath: String, _ included: Bool) throws {
        let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard included else {
            try exclude(path: path)
            return
        }
        let tree = try tree()
        guard var node = tree.folders.values.first(where: { $0.path == path }), node.isExcluded else { return }
        let plain = node.intervalOverride == nil && node.availabilityOverride == nil && !node.isPaused
            && node.excludePatterns.isEmpty && (tree.children[node.id] ?? []).isEmpty && !node.isRoot
        if plain {
            try store.deleteFolder(id: node.id)
        } else {
            node.isExcluded = false
            try store.update(node)
        }
    }

    /// Re-parents managed nodes that sit under a newly inserted node, so inheritance flows through it.
    private func adoptDescendants(of node: ManagedFolder, in tree: FolderTree) throws {
        for var d in tree.folders.values where d.parentID == node.parentID && d.id != node.id
            && FolderTree.relative(d.path, to: node.path) != nil {
            d.parentID = node.id
            try store.update(d)
        }
    }

    /// Stops managing the folder and its descendants. Local files and cloud copies stay as they are.
    public func remove(id: Int64) throws {
        try store.deleteFolder(id: id)
    }

    public func setInterval(id: Int64, _ interval: BackupInterval?) throws {
        try modify(id) {
            $0.intervalOverride = interval
            // Reschedule from the last success so a shorter interval takes effect promptly.
            $0.nextRun = $0.lastSuccess.map { $0.addingTimeInterval((interval ?? FolderTree.defaultInterval).seconds) }
        }
    }

    public func setAvailability(id: Int64, _ mode: AvailabilityMode?) throws {
        try modify(id) { $0.availabilityOverride = mode }
    }

    public func setExcludePatterns(id: Int64, _ patterns: [String]) throws {
        try modify(id) { $0.excludePatterns = ExclusionRules.clean(patterns) }
    }

    public func setPaused(id: Int64, _ paused: Bool) throws {
        try modify(id) {
            $0.isPaused = paused
            $0.status = paused ? .paused : ($0.lastSuccess == nil ? .idle : .backedUp)
        }
    }

    /// Makes the folder due on the next engine tick.
    public func scheduleNow(id: Int64) throws {
        try modify(id) { $0.nextRun = .distantPast }
    }

    private func modify(_ id: Int64, _ change: (inout ManagedFolder) -> Void) throws {
        guard var f = try store.folder(id: id) else { return }
        change(&f)
        try store.update(f)
    }

    func uniqueRemoteName(for path: String, among roots: [ManagedFolder]) -> String {
        let base = Self.sanitize((path as NSString).lastPathComponent)
        let taken = Set(roots.compactMap { $0.remoteName?.lowercased() })
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) (\(n))"
            n += 1
        }
        return name
    }

    /// OneDrive disallows some characters and trailing dots/spaces in names.
    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\"*:<>?/\\|")
        var s = String(name.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        return s.isEmpty ? "Folder" : s
    }
}
