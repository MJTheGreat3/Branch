# Cloud Folder Manager for macOS

## 1. Overview

A native macOS application that lets a user choose folders on their Mac, organise them in a configurable tree, and control how each folder is backed up to a personal OneDrive account. The app should make it easy to see what is protected, when each folder will next be backed up, how much cloud storage is being used, and whether content is kept locally or accessed from the cloud on demand.

The design goal is a single control panel for folder-level backup policies, with a simple interface and a background service that runs when the user is logged in.

## 2. The Problem It Solves

A user may have important folders scattered around their Mac, including documents, source code, media, and large datasets. They want to protect selected folders in OneDrive without manually copying files each time. At the same time, they do not want every backed-up file to consume local disk space.

The app should combine:

- A tree view of selected folders and their children.
- Configurable cloud backup schedules for individual folders.
- A clear local-versus-cloud availability policy for each folder.
- Automatic background processing, status visibility, and recoverable failures.
- A way to manage many folders from one place rather than configuring each separately in Finder.

## 3. Target Platform and Storage

- **Platform:** macOS.
- **Cloud provider:** Microsoft OneDrive, using the user's existing account and storage quota.
- **Preferred native UI:** SwiftUI.
- **Local configuration/state:** SQLite or a similarly reliable local database.
- **Cloud integration:** Microsoft Graph API, with Microsoft sign-in and the minimum permissions needed.
- **Background processing:** A per-user background process or login item, with work scheduled by the app.

The app should work within OneDrive and macOS filesystem APIs rather than trying to bypass their sync and file-provider mechanisms.

## 4. Core User Experience

### 4.1 Add folders

- Let the user select an existing folder using the macOS folder picker.
- Display the chosen folder and its descendants in a navigable tree.
- Allow the user to include or exclude individual child folders and files.
- Allow a folder to be removed from the app's management list without accidentally deleting the source folder or cloud copy.

### 4.2 Folder tree and inherited settings

Each folder row should display its name, local/cloud state, schedule, last successful backup, and current status.

Settings should inherit from a parent folder by default, but users should be able to override them on a child folder. For example, a parent could use an hourly backup interval while a large dataset under it uses a daily interval.

### 4.3 Storage and availability modes

Each folder should have a clearly described policy:

1. **Keep local and in OneDrive** — keep the local content available on the Mac and maintain a corresponding cloud copy.
2. **Cloud-only / on-demand** — keep the content in OneDrive and use supported OneDrive Files On-Demand or File Provider functionality to avoid keeping full file contents on the Mac until needed.

The UI must explain the difference between *backup schedule* and *local availability*. These are separate settings: a folder can be synced continuously by OneDrive while its local contents are online-only.

For the initial release, cloud-only behaviour should use OneDrive's supported managed folder hierarchy and Files On-Demand capabilities. Supporting cloud-only placeholders at arbitrary original filesystem paths may require a custom macOS File Provider extension and should be treated as an advanced phase.

### 4.4 Backup schedules

- Set a different backup interval per folder, such as 15 minutes, 1 hour, 6 hours, daily, or weekly.
- Support inherited intervals and child-folder overrides.
- Show the last successful backup and the next scheduled attempt.
- Allow the user to pause and resume a folder's schedule.
- Queue work while offline and catch up when connectivity returns.
- Avoid repeatedly uploading unchanged files by tracking metadata and, where useful, file hashes.

The schedule is a target cadence, not a guarantee of execution at an exact time. macOS sleep, network availability, login state, and system scheduling can delay work.

### 4.5 Status and storage dashboard

The main view should show:

- Total managed folders and files.
- Last successful backup and next scheduled run for each folder.
- Pending uploads, active transfers, failures, and retry state.
- Local storage used by managed content, where it can be determined reliably.
- Approximate OneDrive storage used by the app's managed content.
- A clear distinction between files successfully uploaded and files still pending.

### 4.6 Background operation

The app should be able to run with its main window closed, display an optional menu-bar status, and continue scheduled work while the user is logged in. It should recover gracefully after a restart and resume queued tasks without requiring the user to start over.

## 5. Functional Requirements

### Must-have for the first useful version

- Add and remove folders from management.
- Persist a hierarchical folder tree and per-folder settings.
- Sign in to OneDrive securely.
- Upload new and changed files to a predictable OneDrive destination.
- Configure an individual backup interval for each folder.
- Run queued backups in the background while the user session is available.
- Show progress, last-success time, errors, and retry controls.
- Never report a backup as successful until the relevant transfer has been confirmed.
- Never delete a local source file as a side effect of a backup.

### Follow-up features

- Local/cloud availability policy controls.
- Parent settings with child-folder overrides.
- Exclusion patterns for temporary files, build folders, caches, and other user-selected paths.
- Bandwidth and concurrency limits.
- Notifications for repeated failures or a completed initial backup.
- Search, filtering, and sorting in the folder tree.
- Conflict detection and clear conflict-resolution choices.
- Versioned backup snapshots and restore workflows.
- Storage quota warnings.
- Import/export of the app's configuration.

## 6. Non-Functional Requirements

- **Reliability:** Interrupted transfers should resume or retry safely; restarts should not lose queue state.
- **Data integrity:** The app should verify transfers where possible and preserve source files until upload verification succeeds.
- **Safety by default:** Do not propagate deletions to the cloud without an explicit, clearly explained policy. Do not silently overwrite conflicting versions.
- **Security:** Use macOS Keychain for tokens and avoid storing passwords directly. Request only necessary OneDrive permissions.
- **Performance:** Detect changes efficiently and avoid rescanning or uploading all content on every run.
- **Transparency:** Clearly label the difference between backup, bidirectional sync, and cloud-only availability.
- **Usability:** Important actions should have understandable states such as *Queued*, *Uploading*, *Backed up*, *Needs attention*, and *Paused*.

## 7. Proposed Technical Architecture

### macOS client

- **SwiftUI:** Main interface, folder tree, settings, progress indicators, and menu-bar interface.
- **Folder access:** macOS file and security-scoped bookmark APIs as appropriate for folders selected by the user.
- **SQLite:** Folder policies, file metadata, remote item identifiers, last-success timestamps, checksums, pending jobs, and errors.
- **Keychain:** Secure storage for authentication tokens and related credentials.

### Backup engine

- Scan managed folders and identify new, modified, moved, or deleted items.
- Apply inclusion/exclusion rules and folder-level schedule policies.
- Maintain a persistent queue of upload tasks.
- Use resumable upload sessions for large files where supported.
- Implement bounded retries, exponential backoff, cancellation, and resumable state.
- Record success only after confirming the remote operation.

### OneDrive integration

- Use Microsoft sign-in and Microsoft Graph with delegated permissions.
- Keep a mapping between local paths and remote OneDrive item IDs.
- Use remote change tracking where appropriate to reduce unnecessary enumeration.
- Define a stable destination structure and behaviour for renamed or moved local folders.
- Handle expired tokens, rate limits, quota errors, offline periods, and API failures.

### Background execution

- Use an appropriate per-user login/background mechanism so the backup engine can run without the main window staying open.
- Re-evaluate due jobs on launch, login, and return from offline periods.
- Treat scheduled times as best effort because macOS may defer work during sleep or when the user session is unavailable.

### Cloud-only support

For an initial release, rely on OneDrive's existing sync client and Files On-Demand within its supported managed folder hierarchy. A later version could implement a custom macOS File Provider extension for a dedicated cloud-backed location in Finder. That advanced version would require metadata enumeration, on-demand downloads (hydration), upload handling, remote change detection, conflict management, and careful testing with filesystem operations.

## 8. Important Product Distinctions

### Backup is not the same as sync

- **Backup:** Copies selected files to the cloud so they can be recovered later.
- **Sync:** Attempts to keep local and cloud versions aligned; deletions and unwanted changes can propagate.
- **Cloud-only availability:** Keeps file contents online while presenting them through OneDrive's managed filesystem integration.

The app should name these behaviours clearly and avoid presenting one as another. A scheduled upload-only backup can be a safer first version than bidirectional synchronisation.

### Deletions and version history

A robust backup must define what happens when a local file is deleted or overwritten. The safe initial behaviour is to retain cloud copies unless the user explicitly enables deletion propagation. Versioned snapshots or OneDrive's available recovery/version-history features should be considered so a mistaken change does not immediately eliminate the only good copy.

### Local paths and cloud placeholders

An ordinary app cannot safely turn any arbitrary folder path on macOS into an online-only placeholder merely by deleting local contents. Cloud-only Finder behaviour is managed by OneDrive's File Provider integration or by a custom File Provider extension. The first implementation should not promise transparent cloud-only operation at arbitrary existing paths.

## 9. Suggested Development Roadmap

### Phase 1 — Scheduled cloud backup MVP

1. Build the SwiftUI folder manager.
2. Add Microsoft sign-in and OneDrive connectivity.
3. Implement folder enumeration, file change detection, upload queueing, and resumable transfers.
4. Add per-folder schedules, persistent state, retry logic, and status reporting.
5. Test interruption recovery, duplicate files, large files, renames, offline mode, and OneDrive quota/API errors.

### Phase 2 — Usability and recovery

1. Add parent/child inheritance and exclusions.
2. Add a menu-bar status indicator and notifications.
3. Add restore, versioning/snapshot strategy, and safer conflict resolution.
4. Add storage usage reporting and performance improvements.

### Phase 3 — Advanced cloud-only management

1. Integrate OneDrive Files On-Demand for content in the supported managed hierarchy.
2. Evaluate whether a custom File Provider extension is necessary.
3. If so, implement a dedicated cloud-backed location and test file hydration, uploads, remote changes, offline behaviour, and Finder compatibility.

## 10. Acceptance Criteria for the MVP

The MVP is usable when:

- A user can add at least two different folders and configure distinct backup intervals.
- The app uploads new and changed files to the intended OneDrive locations.
- Unchanged files are not needlessly uploaded again.
- The app continues queued work after its window closes and recovers after an app or Mac restart, subject to macOS login/background constraints.
- The interface displays accurate task states and useful failure messages.
- A failed or incomplete upload is not shown as a successful backup.
- Local files remain untouched by the backup operation.
- Users can pause, resume, and remove a managed folder without unintentionally deleting its contents.

## 11. App Name Ideas

Names focused on trees and folder structure:

- **CloudTree** — simple and immediately communicates a cloud-backed folder hierarchy.
- **Branch** — short, clean, and based on the idea of child folders and branches.
- **TreeSync** — clear, although it may overemphasise synchronisation rather than backup.
- **FolderCanopy** — suggests a protective layer over a folder tree.
- **RootCloud** — connects root folders with cloud storage.

Names focused on backup and protection:

- **CloudKeep** — memorable and protection-oriented.
- **VaultTree** — combines a folder hierarchy with secure storage.
- **Safekeep** — communicates preservation, though it is a broader name.
- **NestBackup** — suggests keeping files safely in one place.
- **Evercopy** — suggests recurring, maintained copies.

Names focused on automation and organisation:

- **CloudPilot** — an app that manages cloud tasks automatically.
- **FolderFlow** — conveys a smooth workflow for folder management.
- **CloudRoutine** — highlights scheduled background tasks.
- **Branchline** — evokes folder branches and predictable automated routines.
- **SyncNest** — friendly, but potentially implies two-way sync.

### Name recommendation

**CloudTree** is the strongest working title for this concept: it fits the hierarchical folder interface, is easy to say, and leaves room for backup schedules and cloud-only storage features. **CloudKeep** is a strong alternative if you want the product to be understood primarily as a backup and recovery tool.

These are creative suggestions, not verified trademarks or domain availability. Before choosing a final public name, check app-store listings, trademark databases, and relevant domain names.

## 12. Product Summary

Build a native macOS control panel that lets users manage a tree of selected folders, set independent backup schedules, and see reliable OneDrive backup status. Start with scheduled, upload-oriented backups and persistent recovery state. Add supported OneDrive cloud-only behaviour next, and reserve a custom File Provider extension for a later version if transparent Finder integration is essential.
