import AppKit
import BranchCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
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
