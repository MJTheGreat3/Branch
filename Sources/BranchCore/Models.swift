import Foundation

/// Target cadence for a folder's backup. Best effort: sleep, network and login state can delay runs.
public enum BackupInterval: String, CaseIterable, Codable, Sendable, Identifiable {
    case fifteenMinutes
    case hourly
    case sixHours
    case daily
    case weekly

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .hourly: return 60 * 60
        case .sixHours: return 6 * 60 * 60
        case .daily: return 24 * 60 * 60
        case .weekly: return 7 * 24 * 60 * 60
        }
    }

    public var label: String {
        switch self {
        case .fifteenMinutes: return "Every 15 minutes"
        case .hourly: return "Hourly"
        case .sixHours: return "Every 6 hours"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

/// Whether content stays on the Mac. Separate from the backup schedule.
public enum AvailabilityMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case localAndCloud
    case cloudOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .localAndCloud: return "Keep on this Mac and in OneDrive"
        case .cloudOnly: return "Cloud-only (free up space)"
        }
    }

    public var explanation: String {
        switch self {
        case .localAndCloud:
            return "Files stay on this Mac and a copy is kept in OneDrive."
        case .cloudOnly:
            return "Once a file is verified in OneDrive and hasn't changed for a few minutes, Branch moves the local copy to the Trash and leaves a small “.branch” stand-in. Double-click a stand-in, or use Restore, to download it again. Empty the Trash to actually free the space."
        }
    }
}

/// User-facing state of a folder or job.
public enum BackupStatus: String, Codable, Sendable {
    case idle
    case queued
    case uploading
    case backedUp
    case needsAttention
    case paused

    public var label: String {
        switch self {
        case .idle: return "Not yet backed up"
        case .queued: return "Queued"
        case .uploading: return "Uploading"
        case .backedUp: return "Backed up"
        case .needsAttention: return "Needs attention"
        case .paused: return "Paused"
        }
    }
}

/// A folder the user added, or a descendant carrying its own overrides or exclusion.
public struct ManagedFolder: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// nil for a root added via the folder picker.
    public var parentID: Int64?
    public var path: String
    public var bookmark: Data?
    /// Folder name used under the app's OneDrive root. Set only on roots.
    public var remoteName: String?
    public var intervalOverride: BackupInterval?
    public var availabilityOverride: AvailabilityMode?
    public var isPaused: Bool
    public var isExcluded: Bool
    /// Extra exclusion patterns for this subtree, added to the global list and any ancestors'.
    public var excludePatterns: [String]
    public var lastSuccess: Date?
    public var nextRun: Date?
    public var status: BackupStatus
    public var lastError: String?

    public init(
        id: Int64 = 0,
        parentID: Int64? = nil,
        path: String,
        bookmark: Data? = nil,
        remoteName: String? = nil,
        intervalOverride: BackupInterval? = nil,
        availabilityOverride: AvailabilityMode? = nil,
        isPaused: Bool = false,
        isExcluded: Bool = false,
        excludePatterns: [String] = [],
        lastSuccess: Date? = nil,
        nextRun: Date? = nil,
        status: BackupStatus = .idle,
        lastError: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.path = path
        self.bookmark = bookmark
        self.remoteName = remoteName
        self.intervalOverride = intervalOverride
        self.availabilityOverride = availabilityOverride
        self.isPaused = isPaused
        self.isExcluded = isExcluded
        self.excludePatterns = excludePatterns
        self.lastSuccess = lastSuccess
        self.nextRun = nextRun
        self.status = status
        self.lastError = lastError
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var isRoot: Bool { parentID == nil }
}

/// Last known state of a single file under a managed root.
public struct FileRecord: Hashable, Sendable {
    public var rootID: Int64
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    public var sha256: String?
    public var remoteItemID: String?
    public var uploadedAt: Date?
    /// QuickXorHash OneDrive confirmed for the uploaded copy.
    public var quickXorHash: String?
    /// Set while the local copy has been replaced by a `.branch` stand-in.
    public var offloadedAt: Date?
    /// Restored from the cloud recently; kept local for a while even in a cloud-only folder.
    public var restoredAt: Date?

    public init(
        rootID: Int64,
        relativePath: String,
        size: Int64,
        modified: Date,
        sha256: String? = nil,
        remoteItemID: String? = nil,
        uploadedAt: Date? = nil,
        quickXorHash: String? = nil,
        offloadedAt: Date? = nil,
        restoredAt: Date? = nil
    ) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.sha256 = sha256
        self.remoteItemID = remoteItemID
        self.uploadedAt = uploadedAt
        self.quickXorHash = quickXorHash
        self.offloadedAt = offloadedAt
        self.restoredAt = restoredAt
    }
}

public enum JobState: String, Codable, Sendable {
    case queued
    case uploading
    case done
    case failed
}

/// A persisted upload task. Survives restarts.
public struct UploadJob: Identifiable, Hashable, Sendable {
    public var id: Int64
    /// The managed folder whose schedule produced this job.
    public var folderID: Int64
    public var rootID: Int64
    public var relativePath: String
    public var size: Int64
    public var modified: Date
    public var sha256: String?
    public var state: JobState
    public var attempts: Int
    public var notBefore: Date
    public var lastError: String?
    /// Graph resumable upload session URL, if a large upload is in progress.
    public var sessionURL: String?
    public var bytesUploaded: Int64

    public init(
        id: Int64 = 0,
        folderID: Int64,
        rootID: Int64,
        relativePath: String,
        size: Int64,
        modified: Date,
        sha256: String? = nil,
        state: JobState = .queued,
        attempts: Int = 0,
        notBefore: Date = .distantPast,
        lastError: String? = nil,
        sessionURL: String? = nil,
        bytesUploaded: Int64 = 0
    ) {
        self.id = id
        self.folderID = folderID
        self.rootID = rootID
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.sha256 = sha256
        self.state = state
        self.attempts = attempts
        self.notBefore = notBefore
        self.lastError = lastError
        self.sessionURL = sessionURL
        self.bytesUploaded = bytesUploaded
    }
}
