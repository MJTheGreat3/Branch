import Foundation

/// How much room is left in OneDrive relative to what Branch still has to upload.
public enum QuotaLevel: Int, Comparable, Sendable {
    case ok
    /// Less than 10% free.
    case low
    /// Not enough free space for the uploads still waiting.
    case insufficient
    case full

    public static func < (a: QuotaLevel, b: QuotaLevel) -> Bool { a.rawValue < b.rawValue }

    public static func assess(_ quota: DriveQuota, pendingBytes: Int64) -> QuotaLevel {
        guard quota.total > 0 else { return .ok }
        if quota.remaining <= 0 { return .full }
        if pendingBytes > quota.remaining { return .insufficient }
        if Double(quota.remaining) / Double(quota.total) < 0.10 { return .low }
        return .ok
    }

    public var message: String? {
        switch self {
        case .ok: return nil
        case .low: return "OneDrive is almost full (less than 10% free)."
        case .insufficient: return "OneDrive doesn't have enough free space for the files waiting to upload."
        case .full: return "OneDrive is full. Uploads will fail until space is freed."
        }
    }
}

/// Something worth telling the user about outside the window.
public enum BackupEvent: Equatable, Sendable {
    case firstBackupCompleted(folderID: Int64, name: String)
    case needsAttention(folderID: Int64, name: String, reason: String?)
    case recovered(folderID: Int64, name: String)
    case quota(QuotaLevel)

    public var title: String {
        switch self {
        case .firstBackupCompleted(_, let name): return "“\(name)” is backed up"
        case .needsAttention(_, let name, _): return "“\(name)” needs attention"
        case .recovered(_, let name): return "“\(name)” is backing up again"
        case .quota: return "OneDrive storage"
        }
    }

    public var body: String {
        switch self {
        case .firstBackupCompleted: return "The first backup finished. Branch will keep it up to date on its schedule."
        case .needsAttention(_, _, let reason): return reason ?? "Some files couldn't be backed up."
        case .recovered: return "The earlier problem cleared and files are being backed up."
        case .quota(let level): return level.message ?? ""
        }
    }

    /// Diffs two snapshots of the folder table into events. Only transitions count, so a folder
    /// that stays broken is reported once, not on every refresh.
    public static func changes(from old: [ManagedFolder], to new: [ManagedFolder]) -> [BackupEvent] {
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var out: [BackupEvent] = []
        for f in new.sorted(by: { $0.id < $1.id }) {
            guard let prev = before[f.id], !f.isExcluded else { continue }
            if f.isRoot, prev.lastSuccess == nil, f.lastSuccess != nil, f.status == .backedUp {
                out.append(.firstBackupCompleted(folderID: f.id, name: f.name))
            }
            if f.status == .needsAttention, prev.status != .needsAttention {
                out.append(.needsAttention(folderID: f.id, name: f.name, reason: f.lastError))
            } else if prev.status == .needsAttention, f.status == .backedUp || f.status == .uploading {
                out.append(.recovered(folderID: f.id, name: f.name))
            }
        }
        return out
    }

    /// A quota event only when the level gets worse.
    public static func quotaChange(from old: QuotaLevel?, to new: QuotaLevel) -> BackupEvent? {
        new > (old ?? .ok) ? .quota(new) : nil
    }
}
