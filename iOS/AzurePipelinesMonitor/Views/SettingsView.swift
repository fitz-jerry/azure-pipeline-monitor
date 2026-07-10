import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var config: AppConfig
    @Environment(\.dismiss) private var dismiss

    @State private var newProject = ""
    @State private var patInput = ""
    @State private var hasStoredPAT = Keychain.hasPAT
    @State private var patSavedNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("your-org-name", text: $config.organization)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Organization")
                } footer: {
                    Text("The part after https://dev.azure.com/ in your URLs.")
                }

                Section("Projects") {
                    ForEach(config.projects, id: \.self) { project in
                        Text(project)
                    }
                    .onDelete { config.projects.remove(atOffsets: $0) }

                    HStack {
                        TextField("Add a project", text: $newProject)
                            .autocorrectionDisabled()
                            .onSubmit(addProject)
                        Button(action: addProject) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    SecureField(hasStoredPAT ? "•••••• (stored)" : "Paste your PAT", text: $patInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save Token", action: savePAT)
                        .disabled(patInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasStoredPAT {
                        Button("Remove Token", role: .destructive, action: removePAT)
                    }
                    if let note = patSavedNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Personal Access Token")
                } footer: {
                    Text("Scope: Build → Read (use Read & execute to run pipelines and approve). Stored in the iOS Keychain.")
                }

                Section("Notifications") {
                    Toggle("Build started", isOn: $config.notifyOnStart)
                    Toggle("Build completed", isOn: $config.notifyOnComplete)
                    Toggle("Approval required", isOn: $config.notifyOnApproval)
                    Button("Send Test Notification") {
                        NotificationService.shared.sendTest()
                    }
                }

                Section {
                    Stepper("Refresh hint: \(Int(config.refreshSeconds))s",
                            value: $config.refreshSeconds, in: 30...600, step: 30)
                } footer: {
                    Text("A hint for background polling. iOS decides the actual timing and may delay it.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addProject() {
        let trimmed = newProject.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !config.projects.contains(trimmed) else { return }
        config.projects.append(trimmed)
        newProject = ""
    }

    private func savePAT() {
        if Keychain.writePAT(patInput) {
            patInput = ""
            hasStoredPAT = true
            patSavedNote = "Token saved."
            PhoneConnectivity.shared.sync()
        } else if Keychain.lastFailureWasMissingEntitlement {
            // -34018: the app isn't signed with a keychain entitlement. Happens
            // when it was installed unsigned; running from Xcode with a signing
            // team selected fixes it.
            patSavedNote = "Keychain unavailable — run the app from Xcode with a signing team selected (Signing & Capabilities)."
        } else {
            patSavedNote = "Could not save token — \(Keychain.message(for: Keychain.lastStatus))."
        }
    }

    private func removePAT() {
        Keychain.deletePAT()
        hasStoredPAT = false
        patSavedNote = "Token removed."
        PhoneConnectivity.shared.sync()
    }
}
