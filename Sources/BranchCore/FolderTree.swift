import Foundation

/// Effective settings for a folder after inheritance.
public struct EffectivePolicy: Equatable, Sendable {
    public var interval: BackupInterval
    public var availability: AvailabilityMode
    public var isPaused: Bool
    public var isExcluded: Bool
    /// True when interval came from this folder rather than an ancestor or the default.
    public var intervalIsOverridden: Bool
    public var availabilityIsOverridden: Bool
}

/// In-memory view of the managed folder hierarchy with inheritance rules.
///
/// Managed folders are roots (added by the user) plus descendants that carry
/// overrides or exclusions. Each non-excluded managed folder owns the files in
/// its subtree except those under a deeper managed folder.
public struct FolderTree: Sendable {
    public static let defaultInterval: BackupInterval = .hourly
    public static let defaultAvailability: AvailabilityMode = .localAndCloud

    public let folders: [Int64: ManagedFolder]
    public let children: [Int64: [ManagedFolder]]
    public let roots: [ManagedFolder]

    public init(_ list: [ManagedFolder]) {
        var byID: [Int64: ManagedFolder] = [:]
        var kids: [Int64: [ManagedFolder]] = [:]
        var roots: [ManagedFolder] = []
        for f in list {
            byID[f.id] = f
            if let p = f.parentID {
                kids[p, default: []].append(f)
            } else {
                roots.append(f)
            }
        }
        for k in kids.keys {
            kids[k]?.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        roots.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.folders = byID
        self.children = kids
        self.roots = roots
    }

    /// Chain from the folder up to its root, folder first.
    public func lineage(of id: Int64) -> [ManagedFolder] {
        var out: [ManagedFolder] = []
        var cur = folders[id]
        var seen = Set<Int64>()
        while let f = cur, seen.insert(f.id).inserted {
            out.append(f)
            cur = f.parentID.flatMap { folders[$0] }
        }
        return out
    }

    public func root(of id: Int64) -> ManagedFolder? {
        lineage(of: id).last
    }

    public func policy(for id: Int64) -> EffectivePolicy {
        let chain = lineage(of: id)
        let intervalSource = chain.first { $0.intervalOverride != nil }
        let availabilitySource = chain.first { $0.availabilityOverride != nil }
        return EffectivePolicy(
            interval: intervalSource?.intervalOverride ?? Self.defaultInterval,
            availability: availabilitySource?.availabilityOverride ?? Self.defaultAvailability,
            isPaused: chain.contains { $0.isPaused },
            isExcluded: chain.contains { $0.isExcluded },
            intervalIsOverridden: intervalSource?.id == id,
            availabilityIsOverridden: availabilitySource?.id == id
        )
    }

    /// Extra exclusion patterns that apply to a folder: its own plus all ancestors', root first.
    public func excludePatterns(for id: Int64) -> [String] {
        lineage(of: id).reversed().flatMap(\.excludePatterns)
    }

    /// Folders whose schedule is due at `now`.
    public func dueFolders(now: Date) -> [ManagedFolder] {
        folders.values
            .filter { f in
                let p = policy(for: f.id)
                guard !p.isPaused, !p.isExcluded else { return false }
                return (f.nextRun ?? .distantPast) <= now
            }
            .sorted { ($0.nextRun ?? .distantPast) < ($1.nextRun ?? .distantPast) }
    }

    /// Absolute paths under `id` that its scan must skip: deeper managed folders
    /// (they run on their own schedule) and exclusions.
    public func skippedPaths(under id: Int64) -> Set<String> {
        // Direct managed children own their whole subtree, whether excluded or separately scheduled.
        Set((children[id] ?? []).map(\.path))
    }

    /// Next run after a completed backup.
    public func nextRun(for id: Int64, after date: Date) -> Date {
        date.addingTimeInterval(policy(for: id).interval.seconds)
    }

    /// Path of `absolutePath` relative to the folder's root, or nil if outside it.
    public func relativePath(_ absolutePath: String, rootID: Int64) -> String? {
        guard let root = folders[rootID] else { return nil }
        return FolderTree.relative(absolutePath, to: root.path)
    }

    public static func relative(_ path: String, to base: String) -> String? {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        if path == b { return "" }
        guard path.hasPrefix(b + "/") else { return nil }
        return String(path.dropFirst(b.count + 1))
    }

    /// Finds an existing managed folder that contains `path` (or equals it).
    public func containing(_ path: String) -> ManagedFolder? {
        folders.values
            .filter { FolderTree.relative(path, to: $0.path) != nil }
            .max { $0.path.count < $1.path.count }
    }
}
