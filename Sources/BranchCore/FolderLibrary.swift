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
                return try store.insert(ManagedFolder(parentID: parent.id, path: path, bookmark: bookmark))
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
        return try store.insert(ManagedFolder(parentID: parent.id, path: path, isExcluded: excluded))
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
