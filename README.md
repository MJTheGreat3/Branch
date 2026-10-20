# Branch

Native macOS control panel for backing up a tree of selected folders to OneDrive on per-folder schedules.

See [docs/cloud_folder_manager_app_brief.md](docs/cloud_folder_manager_app_brief.md) for the product brief.

## Status

Phase 1 (scheduled backup MVP) in progress:

- Add/remove folders, tree with inherited settings and child overrides, exclusions.
- Per-folder schedules (15 min → weekly), pause/resume, back up now.
- Change detection by size/mtime, then SHA-256, so unchanged files are never re-uploaded.
- Persistent upload queue in SQLite; resumable Graph upload sessions for files over 4 MB.
- Bounded retries with exponential backoff; honours `Retry-After`.
- A file only counts as backed up after Graph returns the item and both its size and QuickXorHash match the local file.
- Upload-only: local deletions are never propagated, local files are never modified.
- Menu-bar status, keeps running with the window closed, optional login item.

Cloud-only availability is recorded per folder but only takes effect for folders inside OneDrive's own synced folder (Phase 3).

## OneDrive setup

Branch signs in with the device-code flow and needs your own Azure app registration:

1. In the [Azure portal](https://portal.azure.com) → App registrations → New registration.
   Supported account types: *Personal Microsoft accounts only* (or include work/school).
2. Authentication → enable **Allow public client flows**.
3. API permissions → Microsoft Graph → Delegated: `Files.ReadWrite.AppFolder`, `offline_access`.
4. Copy the Application (client) ID into Branch → Account.

Backups land in `OneDrive/Apps/Branch/<folder name>/…`. Tokens are kept in the Keychain.

## Layout

- `Sources/BranchCore` — models, SQLite store, folder tree, scanner, backup engine, Graph client, auth, Keychain.
- `Sources/Branch` — SwiftUI app and menu-bar extra.
- `Tests/BranchCoreTests` — unit tests for the core.

## Build

```sh
swift build
swift test
./scripts/bundle.sh      # produces build/Branch.app
open build/Branch.app
```

Requires macOS 14+ and Xcode 16+. App state lives in `~/Library/Application Support/Branch/branch.sqlite`.
