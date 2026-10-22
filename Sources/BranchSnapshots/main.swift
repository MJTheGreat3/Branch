import AppKit
import BranchCore
import BranchUI
import SwiftUI

// Renders Branch's main screens with sample data to PNG files, offscreen.
// Usage: swift run BranchSnapshots [output-dir]

@MainActor
func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    window.appearance = host.appearance
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    host.layoutSubtreeIfNeeded()
    // Capture the window's own backing store; layer-backed lists and forms don't draw via cacheDisplay.
    guard let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
    ) else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
    print("wrote \(url.path)")
}

/// Builds a realistic folder on disk and a store describing it.
@MainActor
func sampleModel(base: URL) throws -> (AppModel, ManagedFolder) {
    let fm = FileManager.default
    let tree = [
        "Projects/branch/Sources", "Projects/branch/.build", "Projects/branch/node_modules",
        "Projects/website/public", "Photos/2024", "Photos/2025/raw", "Datasets/large",
        "Notes",
    ]
    for d in tree {
        try fm.createDirectory(at: base.appendingPathComponent("Documents/\(d)"), withIntermediateDirectories: true)
    }
    for f in ["Notes/todo.md", "Notes/ideas.txt", "Projects/branch/README.md", "Photos/2025/raw/IMG_0001.CR3",
              "Photos/2024/beach.jpg", "Datasets/large/survey.csv", "budget.xlsx", "tmp.swp"] {
        try Data("sample".utf8).write(to: base.appendingPathComponent("Documents/\(f)"))
    }

    let store = try Store(db: Database(path: ":memory:"))
    let library = FolderLibrary(store: store)
    let docsPath = base.appendingPathComponent("Documents").path
    var root = try library.add(path: docsPath)
    try library.setInterval(id: root.id, .hourly)
    let datasets = try library.add(path: docsPath + "/Datasets")
    try library.setInterval(id: datasets.id, .weekly)
    try library.setIncluded(path: docsPath + "/Photos/2025/raw", false)
    try library.setIncluded(path: docsPath + "/budget.xlsx", false)

    root = try store.folder(id: root.id)!
    root.lastSuccess = Date().addingTimeInterval(-40 * 60)
    root.nextRun = Date().addingTimeInterval(20 * 60)
    root.status = .backedUp
    try store.update(root)
    try store.upsert(FileRecord(rootID: root.id, relativePath: "Notes/todo.md", size: 12_000, modified: Date(), uploadedAt: Date()))
    try store.upsert(FileRecord(rootID: root.id, relativePath: "Photos/2024/beach.jpg", size: 4_200_000, modified: Date(),
                                uploadedAt: Date(), offloadedAt: Date()))
    try library.setAvailability(id: root.id, .cloudOnly)
    let beach = base.appendingPathComponent("Documents/Photos/2024/beach.jpg").path
    try StandIn(name: "beach.jpg", size: 4_200_000, modified: Date(), quickXorHash: "x", remotePath: "Documents/Photos/2024/beach.jpg",
                offloadedAt: Date()).write(to: StandIn.path(for: beach))
    try fm.removeItem(atPath: beach)

    let model = AppModel(store: store, live: false, keychain: Keychain(service: "com.branch.snapshots"))
    return (model, root)
}

struct Missing: Error {}
func XCTUnwrapLike<T>(_ v: T?) throws -> T {
    guard let v else { throw Missing() }
    return v
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/snapshots", isDirectory: true)
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("branch-snap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }

    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (model, root) = try sampleModel(base: base.resolvingSymlinksInPath())

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            try render(SnapshotPanes.overview().environmentObject(model), size: CGSize(width: 760, height: 760), dark: dark,
                       to: out.appendingPathComponent("overview\(suffix).png"))
            let fresh = try XCTUnwrapLike(model.tree.folders[root.id])
            try render(SnapshotPanes.folder(fresh).environmentObject(model), size: CGSize(width: 760, height: 1100), dark: dark,
                       to: out.appendingPathComponent("folder\(suffix).png"))
            try render(SnapshotPanes.sidebar().environmentObject(model), size: CGSize(width: 300, height: 500), dark: dark,
                       to: out.appendingPathComponent("sidebar\(suffix).png"))
            let expanded: Set<String> = [root.path + "/Photos", root.path + "/Photos/2024", root.path + "/Photos/2025", root.path + "/Projects",
                                         root.path + "/Projects/branch"]
            try render(ContentsBrowser(folder: root, expanded: expanded).environmentObject(model),
                       size: CGSize(width: 680, height: 600), dark: dark,
                       to: out.appendingPathComponent("contents\(suffix).png"))
        }
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}
