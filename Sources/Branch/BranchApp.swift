import AppKit
import BranchCore
import BranchUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once its model exists; stand-ins opened before then wait here.
    var model: AppModel? {
        didSet { pending.forEach(handle); pending = [] }
    }
    private var pending: [URL] = []

    /// Double-clicking a `.branch` stand-in in Finder restores the file and opens it.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        guard let model else {
            pending.append(url)
            return
        }
        model.restore(standIn: url, open: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare SwiftPM executable rather than a bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
