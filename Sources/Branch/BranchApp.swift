import AppKit
import BranchCore
import BranchUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once its model exists; stand-ins opened before then wait here.
    var model: AppModel? {
        didSet {
            let waiting = pending
            pending = []
            if !waiting.isEmpty { handle(waiting) }
        }
    }
    private var pending: [URL] = []

    /// Double-clicking a `.branch` stand-in, choosing Open With → Branch on a folder, or dropping
    /// items on the Dock icon restores them in place.
    func application(_ application: NSApplication, open urls: [URL]) {
        handle(urls)
    }

    private func handle(_ urls: [URL]) {
        guard let model else {
            pending.append(contentsOf: urls)
            return
        }
        model.restore(urls)
    }

    /// Finder's Services menu: "Restore from OneDrive (Branch)".
    @objc func restoreFromCloud(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Select files or folders to restore." as NSString
            return
        }
        handle(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare SwiftPM executable rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Keep backing up from the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct BranchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Branch", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Back Up All Now") { model.backUpAllNow() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        switch model.overallStatus {
        case .uploading, .queued: return "arrow.triangle.2.circlepath.icloud"
        case .needsAttention: return "exclamationmark.icloud"
        default: return "checkmark.icloud"
        }
    }
}
