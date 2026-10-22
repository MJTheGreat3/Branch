import BranchCore
import ServiceManagement
import SwiftUI

/// OneDrive connection and app preferences.
struct AccountView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var signIn: SignInState = .idle
    @State private var signInTask: Task<Void, Never>?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var patternsText = ""

    enum SignInState: Equatable {
        case idle
        case requesting
        case waiting(DeviceCodePrompt)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Application (client) ID", text: $model.clientID)
                    .font(.body.monospaced())
                    .onSubmit { model.saveClientID() }
                Button("Save") { model.saveClientID() }
            } header: {
                Text("Microsoft app registration")
            } footer: {
                Text("Register a public client app in the Azure portal, enable “Allow public client flows”, and add the delegated permissions Files.ReadWrite.AppFolder and offline_access. Branch only gets access to its own Apps/Branch folder.")
            }

            Section("OneDrive") {
                if model.isSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Sign Out", role: .destructive) { model.signOut() }
                } else {
                    switch signIn {
                    case .idle:
                        Button("Sign In with Microsoft…") { startSignIn() }
                            .disabled(model.clientID.isEmpty)
                    case .requesting:
                        ProgressView().controlSize(.small)
                    case .waiting(let prompt):
                        Text(prompt.message).font(.callout)
                        HStack {
                            Text(prompt.userCode)
                                .font(.title2.monospaced().bold())
                                .textSelection(.enabled)
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(prompt.userCode, forType: .string)
                            }
                            Button("Open Sign-In Page") { NSWorkspace.shared.open(prompt.verificationURL) }
                        }
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to finish signing in…").foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { cancelSignIn() }
                        }
                    case .failed(let message):
                        Text(message).foregroundStyle(.orange)
                        Button("Try Again") { startSignIn() }
                    }
                }
            }

            Section {
                TextEditor(text: $patternsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                HStack {
                    Button("Save") { model.setGlobalPatterns(patternsText) }
                        .disabled(ExclusionRules.parse(patternsText) == model.globalPatterns)
                    Button("Restore Defaults") {
                        model.setGlobalPatterns(nil)
                        patternsText = model.globalPatterns.joined(separator: "\n")
                    }
                }
            } header: {
                Text("Skipped files")
            } footer: {
                Text("One pattern per line, applied to every folder. Use * and ? as wildcards. A pattern without / matches any file or folder name (*.tmp, node_modules); with / it matches a path inside the managed folder (Projects/*/build). Takes effect at the next backup; files already in OneDrive are kept.")
            }

            Section {
                Toggle("Open Branch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                Toggle("Notify me about problems, finished first backups and low storage", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { model.setNotificationsEnabled($0) }
                ))
            } header: {
                Text("Background")
            } footer: {
                Text("Branch keeps running in the menu bar after you close its window, and backs up while you're logged in.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { patternsText = model.globalPatterns.joined(separator: "\n") }
        .onDisappear { signInTask?.cancel() }
    }

    private func startSignIn() {
        model.saveClientID()
        signIn = .requesting
        signInTask = Task {
            do {
                let start = try await model.auth.startDeviceCode()
                signIn = .waiting(start.prompt)
                NSWorkspace.shared.open(start.prompt.verificationURL)
                try await model.auth.completeDeviceCode(
                    start.deviceCode, interval: start.interval, expiresAt: start.prompt.expiresAt
                )
                await model.refreshAuthState()
                signIn = .idle
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed(String(describing: error))
            }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signIn = .idle
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            model.errorMessage = "Couldn't change login item: \(error.localizedDescription). Run Branch from its .app bundle."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
