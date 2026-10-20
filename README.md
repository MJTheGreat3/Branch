# Branch

Native macOS control panel for backing up a tree of selected folders to OneDrive on per-folder schedules.

See [docs/cloud_folder_manager_app_brief.md](docs/cloud_folder_manager_app_brief.md) for the product brief.

## Layout

- `Sources/BranchCore` — models, SQLite store, scanner, scheduler, backup engine, OneDrive (Microsoft Graph) client, Keychain.
- `Sources/Branch` — SwiftUI app and menu-bar extra.
- `Tests/BranchCoreTests` — unit tests for the core.

## Build

```sh
swift build
swift test
./scripts/bundle.sh      # produces build/Branch.app
```

Requires macOS 14+ and Xcode 16+.
